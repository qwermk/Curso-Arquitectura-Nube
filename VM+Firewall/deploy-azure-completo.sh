#!/bin/bash

# =====================================================================
# SCRIPT: deploy-azure-completo.sh
# DESCRIPCIÓN:
#   Despliegue completo de infraestructura Azure con:
#     1) Red virtual (VNet) con dos subredes (workload + firewall)
#     2) Dos máquinas virtuales (Linux Ubuntu + Windows Server)
#        SIN IP pública (acceso exclusivo vía Firewall DNAT)
#     3) Azure Firewall con IP pública estática
#     4) UDR (User Defined Route) para forzar todo el tráfico
#        de la subred workload a través del Firewall
#     5) Firewall Policy con reglas DNAT y Network:
#        - DNAT: redirige puertos externos a IPs privadas de VMs
#        - Network: permite tráfico RDP/SSH/HTTP/HTTPS hacia la subred
#
# ARQUITECTURA DE RED:
#   Internet → [Firewall Public IP] → Azure Firewall (10.0.0.0/26)
#     ├── DNAT :3389 → Windows VM (10.0.1.x:3389)
#     └── DNAT :2201 → Linux VM   (10.0.1.x:22)
#   Subred workload (10.0.1.0/24) → UDR → todo tráfico sale por Firewall
#
# CARACTERÍSTICAS:
#   - Idempotente: no recrea recursos que ya existen
#   - No destructivo: no borra reglas existentes
#   - Maneja consistencia eventual de Azure (waits con polling)
#   - Log completo de la ejecución
#
# PREREQUISITOS:
#   - Azure CLI instalado y autenticado (az login)
#   - Suscripción Azure activa con permisos de Contributor
#   - Ejecutar en Azure Cloud Shell (Bash) o terminal con az CLI
#
# USO:
#   chmod +x deploy-azure-completo.sh
#   bash deploy-azure-completo.sh
#
# ⚠️  NO ejecutar con 'source' (si hay error, cierra la sesión).
# =====================================================================

# Modo estricto de Bash:
#   -e: salir inmediatamente si un comando falla
#   -u: error si se usa una variable no definida
#   -o pipefail: el código de salida de un pipe es el del último comando que falle
set -euo pipefail

# Archivo de log: registra toda la salida (stdout + stderr)
# Se usa $HOME para compatibilidad con Azure Cloud Shell
LOG_FILE="$HOME/deploy-azure-completo.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =====================================================================
# FUNCIONES DE ESPERA (CONSISTENCIA EVENTUAL DE AZURE)
# =====================================================================
# Azure no garantiza que un recurso esté disponible inmediatamente
# después de crearlo (eventual consistency). Estas funciones hacen
# polling hasta que el recurso aparece en la API, o timeout.
# =====================================================================

# Espera hasta que el Firewall tenga la Policy asociada.
# Tras ejecutar 'az network firewall update --no-wait', la asociación
# se procesa en segundo plano. Timeout: 30 minutos (operación lenta).
wait_for_firewall_policy_association() {
  local timeout_seconds=1800   # 30 min — la asociación puede tardar
  local elapsed=0
  local current_policy_id=""

  while (( elapsed < timeout_seconds )); do
    current_policy_id=$(az network firewall show \
      --resource-group "$RESOURCE_GROUP" \
      --name "$FIREWALL_NAME" \
      --query "firewallPolicy.id" \
      --output tsv 2>/dev/null || true)

    if [[ "$current_policy_id" == "$POLICY_ID" ]]; then
      echo "✅ Firewall Policy asociada correctamente"
      return 0
    fi

    echo "⏳ Esperando asociación de Firewall Policy... (${elapsed}s)"
    sleep 15
    elapsed=$((elapsed + 15))
  done

  echo "❌ Timeout esperando asociación de Firewall Policy"
  return 1
}

# Espera hasta que el Rule Collection Group sea visible en la Policy.
# Tras crearlo, puede tardar unos segundos en propagarse.
# Timeout: 15 minutos.
wait_for_policy_rcg() {
  local timeout_seconds=900    # 15 min
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if az network firewall policy rule-collection-group show \
      --resource-group "$RESOURCE_GROUP" \
      --policy-name "$POLICY_NAME" \
      --name "$RCG_NAME" \
      --query "name" \
      --output tsv >/dev/null 2>&1; then
      return 0
    fi

    echo "⏳ Esperando propagación del Rule Collection Group... (${elapsed}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "❌ Timeout esperando Rule Collection Group"
  return 1
}

# Espera hasta que una Rule Collection (NAT o Network) sea visible
# dentro del Rule Collection Group. Necesario antes de añadir reglas
# individuales, porque Azure puede devolver "The request is invalid"
# si la collection aún no se propagó.
wait_for_policy_collection() {
  local collection_name="$1"
  local timeout_seconds=900    # 15 min
  local elapsed=0
  local found=""

  while (( elapsed < timeout_seconds )); do
    found=$(az network firewall policy rule-collection-group show \
      --resource-group "$RESOURCE_GROUP" \
      --policy-name "$POLICY_NAME" \
      --name "$RCG_NAME" \
      --query "ruleCollections[?name=='$collection_name'] | [0].name" \
      --output tsv 2>/dev/null || true)

    if [[ -n "$found" && "$found" != "null" ]]; then
      return 0
    fi

    echo "⏳ Esperando propagación de la collection $collection_name... (${elapsed}s)"
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "❌ Timeout esperando collection $collection_name"
  return 1
}

# =====================================================================
# VARIABLES DE CONFIGURACIÓN
# =====================================================================
# Modifica estas variables para adaptar el despliegue a tu entorno.
# =====================================================================

# --- Grupo de recursos y ubicación ---
RESOURCE_GROUP="GrupNube"        # Nombre del Resource Group
LOCATION="eastus2"               # Región Azure (East US 2)

# --- Red Virtual (VNet) ---
VNET_NAME="NubeVnet"             # Nombre de la VNet
VNET_PREFIX="10.0.0.0/16"        # Espacio de direcciones completo (65.536 IPs)

# Subred de carga de trabajo (donde se colocan las VMs)
SUBNET_WORKLOAD_NAME="SubNetHome"
SUBNET_WORKLOAD_PREFIX="10.0.1.0/24"       # 254 hosts disponibles

# Subred del Firewall (nombre OBLIGATORIO: "AzureFirewallSubnet")
# Azure Firewall exige este nombre exacto para funcionar.
SUBNET_FIREWALL_NAME="AzureFirewallSubnet"
SUBNET_FIREWALL_PREFIX="10.0.0.0/26"       # /26 mínimo requerido (62 hosts)

# --- Máquinas Virtuales ---
LINUX_VM_NAME="vps-linux-01"               # VM Linux (Ubuntu 22.04)
WINDOWS_VM_NAME="vps-windows-01"           # VM Windows (Server 2022)
VM_SIZE="Standard_D2s_v3"                  # 2 vCPU, 8 GB RAM
LINUX_IMAGE="Ubuntu2204"                   # Imagen de Ubuntu
WINDOWS_IMAGE="Win2022Datacenter"          # Imagen de Windows Server
ADMIN_USER="azureuser"                     # Usuario administrador
WINDOWS_PASSWORD="Admin123456."            # Contraseña Windows (cambiar en producción)

# Si true, las VMs se crean SIN IP pública.
# El acceso se realiza exclusivamente a través de DNAT en el Firewall.
# Esto mejora la seguridad al no exponer las VMs directamente a Internet.
CREATE_VM_WITHOUT_PUBLIC_IP="true"

# --- Azure Firewall ---
FIREWALL_NAME="NubeFirewall"               # Nombre del Firewall
FIREWALL_PUBLIC_IP_NAME="NubeFirewallPublicIP"  # IP pública del Firewall
FIREWALL_IPCONFIG_NAME="NubeFirewallConfig"     # Nombre de la IP config
FIREWALL_SKU="AZFW_VNet"                   # SKU: desplegado dentro de VNet
FIREWALL_TIER="Standard"                   # Tier: Standard (no Premium)

# --- UDR (User Defined Route) ---
# Tabla de rutas que fuerza TODO el tráfico saliente de la subred
# workload a pasar por el Firewall (0.0.0.0/0 → Firewall Private IP).
ROUTE_TABLE_NAME="rt-workload-to-firewall"
ROUTE_NAME_DEFAULT="default-to-firewall"

# --- Firewall Policy ---
# Azure Firewall Policy es el modelo moderno de reglas (reemplaza
# las "classic rule collections"). NO pueden coexistir ambos modelos.
POLICY_NAME="NubeFirewallPolicy"           # Nombre de la policy
RCG_NAME="Default-Connection-Policies"     # Rule Collection Group (agrupa collections)
NAT_COLLECTION_NAME="DNAT-Inbound"         # Collection para reglas DNAT (port forwarding)
NETWORK_COLLECTION_NAME="Allow-Admin-Web"  # Collection para reglas de red (allow/deny)

# --- Puertos externos (DNAT) ---
# El Firewall escucha en estos puertos y redirige a las VMs.
RDP_EXTERNAL_PORT="3389"   # Puerto externo → Windows VM :3389 (RDP)
SSH_EXTERNAL_PORT="2201"   # Puerto externo → Linux VM :22 (SSH)

echo "🚀 Iniciando despliegue completo..."
echo "📝 Log en: $LOG_FILE"
az config set extension.use_dynamic_install=yes_without_prompt --output none
az account show --output none

# =====================================================================
# FUNCIONES HELPER DE IDEMPOTENCIA
# =====================================================================
# Cada función verifica si un recurso Azure ya existe.
# Retorna 0 (true) si existe, 1 (false) si no.
# Esto permite que el script sea idempotente: ejecutar múltiples
# veces sin duplicar ni romper recursos existentes.
# =====================================================================

# Verifica si una VM existe en el resource group
exists_vm() {
  az vm show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el Resource Group existe
exists_resource_group() {
  [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]]
}

# Verifica si la VNet existe
exists_vnet() {
  az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una subred existe dentro de la VNet
exists_subnet() {
  az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una IP pública existe
exists_public_ip() {
  az network public-ip show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el Azure Firewall existe
exists_firewall() {
  az network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si la configuración IP del Firewall ya está vinculada a la VNet
exists_firewall_ip_config() {
  az network firewall ip-config list -g "$RESOURCE_GROUP" -f "$FIREWALL_NAME" --query "[?name=='$FIREWALL_IPCONFIG_NAME'].name | [0]" -o tsv >/dev/null 2>&1
}

# Verifica si la tabla de rutas (UDR) existe
exists_route_table() {
  az network route-table show -g "$RESOURCE_GROUP" -n "$ROUTE_TABLE_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si la ruta por defecto existe en la tabla de rutas
exists_route() {
  az network route-table route show -g "$RESOURCE_GROUP" --route-table-name "$ROUTE_TABLE_NAME" -n "$ROUTE_NAME_DEFAULT" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si la Firewall Policy existe
exists_firewall_policy() {
  az network firewall policy show -g "$RESOURCE_GROUP" -n "$POLICY_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el Firewall ya tiene una Policy asociada.
# IMPORTANTE: Azure Firewall NO permite tener reglas clásicas y Policy
# al mismo tiempo. Si ya tiene policy, no se necesita limpieza.
firewall_has_policy() {
  [[ -n "$(az network firewall show -g "$RESOURCE_GROUP" -n "$FIREWALL_NAME" --query "firewallPolicy.id" -o tsv 2>/dev/null || true)" ]]
}

# Verifica si el Rule Collection Group existe en la Policy
exists_policy_rcg() {
  az network firewall policy rule-collection-group show -g "$RESOURCE_GROUP" --policy-name "$POLICY_NAME" -n "$RCG_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una Rule Collection (NAT o Network) existe dentro del RCG.
# Usa JMESPath para filtrar por nombre dentro del array ruleCollections.
exists_policy_collection() {
  local found
  found=$(az network firewall policy rule-collection-group show \
    -g "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    -n "$RCG_NAME" \
    --query "ruleCollections[?name=='$1'] | [0].name" \
    -o tsv 2>/dev/null || true)
  [[ -n "$found" && "$found" != "null" ]]
}

# Verifica si una regla individual existe dentro de una collection.
# Obtiene todos los nombres de reglas de la collection y busca coincidencia exacta
# con grep -qx (match de línea completa) para evitar falsos positivos.
exists_policy_rule() {
  local collection_name="$1"
  local rule_name="$2"
  local names
  names=$(az network firewall policy rule-collection-group show \
    -g "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    -n "$RCG_NAME" \
    --query "ruleCollections[?name=='${collection_name}'].rules[].name" \
    -o tsv 2>/dev/null || true)
  echo "$names" | grep -qx "$rule_name" 2>/dev/null
}

# =====================================================================
# FASE 1: RED BASE (VNet + Subredes)
# =====================================================================
# Crea la infraestructura de red:
#   - Resource Group: contenedor lógico de todos los recursos
#   - VNet 10.0.0.0/16: red virtual principal
#   - SubNetHome 10.0.1.0/24: subred para las VMs de trabajo
#   - AzureFirewallSubnet 10.0.0.0/26: subred exclusiva del Firewall
# =====================================================================
echo "📦 Creando/actualizando Resource Group..."
if exists_resource_group; then
  echo "ℹ️ Resource Group ya existe, se omite creación."
else
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
fi

echo "🌐 Creando/actualizando VNet y subred workload..."
if exists_vnet; then
  echo "ℹ️ VNet ya existe, se omite creación."
else
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_PREFIX" \
    --subnet-name "$SUBNET_WORKLOAD_NAME" \
    --subnet-prefix "$SUBNET_WORKLOAD_PREFIX" \
    --output none
fi

echo "🔥 Creando/actualizando subred de firewall..."
if exists_subnet "$SUBNET_FIREWALL_NAME"; then
  echo "ℹ️ Subred de firewall ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_FIREWALL_NAME" \
    --address-prefixes "$SUBNET_FIREWALL_PREFIX" \
    --output none
fi

# =====================================================================
# FASE 1b: MÁQUINAS VIRTUALES
# =====================================================================
# Crea dos VMs en la subred workload (SubNetHome):
#   - vps-linux-01:   Ubuntu 22.04 (sin IP pública, acceso SSH por DNAT)
#   - vps-windows-01: Windows Server 2022 (sin IP pública, acceso RDP por DNAT)
#
# Sin IP pública las VMs son inaccesibles desde Internet directamente.
# El acceso se realiza a través de DNAT en el Firewall:
#   Firewall:3389 → Windows:3389 (RDP)
#   Firewall:2201 → Linux:22     (SSH)
# =====================================================================
if exists_vm "$LINUX_VM_NAME"; then
  echo "ℹ️ VM Linux ya existe, se omite creación."
else
  echo "💻 Creando VM Linux..."
  if [[ "$CREATE_VM_WITHOUT_PUBLIC_IP" == "true" ]]; then
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$LINUX_VM_NAME" \
      --image "$LINUX_IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --generate-ssh-keys \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_WORKLOAD_NAME" \
      --public-ip-address "" \
      --output none
  else
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$LINUX_VM_NAME" \
      --image "$LINUX_IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --generate-ssh-keys \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_WORKLOAD_NAME" \
      --public-ip-sku Standard \
      --output none
  fi
fi

if exists_vm "$WINDOWS_VM_NAME"; then
  echo "ℹ️ VM Windows ya existe, se omite creación."
else
  echo "🪟 Creando VM Windows..."
  if [[ "$CREATE_VM_WITHOUT_PUBLIC_IP" == "true" ]]; then
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$WINDOWS_VM_NAME" \
      --image "$WINDOWS_IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --admin-password "$WINDOWS_PASSWORD" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_WORKLOAD_NAME" \
      --public-ip-address "" \
      --output none
  else
    az vm create \
      --resource-group "$RESOURCE_GROUP" \
      --name "$WINDOWS_VM_NAME" \
      --image "$WINDOWS_IMAGE" \
      --size "$VM_SIZE" \
      --admin-username "$ADMIN_USER" \
      --admin-password "$WINDOWS_PASSWORD" \
      --vnet-name "$VNET_NAME" \
      --subnet "$SUBNET_WORKLOAD_NAME" \
      --public-ip-sku Standard \
      --output none
  fi
fi

# ----- Apertura de puertos en NSG (Network Security Group) -----
# Cada VM tiene un NSG automático que bloquea todo por defecto.
# Se abren los puertos necesarios para que el tráfico DNAT del
# Firewall pueda llegar a las VMs. Sin esto, el Firewall redirige
# el tráfico pero el NSG de la VM lo bloquearía.
# Puertos: 22 (SSH), 3389 (RDP), 80 (HTTP), 443 (HTTPS)
# El "|| true" evita que el script falle si la regla ya existe.
echo "🛡️ Abriendo puertos en NSG de VMs (22/3389/80/443)..."
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_NAME" --port 22 --priority 1200 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_NAME" --port 3389 --priority 1210 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_NAME" --port 80 --priority 1220 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_NAME" --port 443 --priority 1230 --output none || true

az vm open-port --resource-group "$RESOURCE_GROUP" --name "$WINDOWS_VM_NAME" --port 22 --priority 1300 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$WINDOWS_VM_NAME" --port 3389 --priority 1310 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$WINDOWS_VM_NAME" --port 80 --priority 1320 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$WINDOWS_VM_NAME" --port 443 --priority 1330 --output none || true

# =====================================================================
# FASE 2: AZURE FIREWALL + UDR (túnel de tráfico)
# =====================================================================
# Crea y configura el Azure Firewall:
#   1. IP pública estática (Standard SKU): punto de entrada desde Internet
#   2. Azure Firewall: inspecciona y filtra todo el tráfico
#   3. IP Config: vincula el Firewall a la VNet + IP pública
#   4. UDR (User Defined Route): fuerza que TODO el tráfico saliente
#      de SubNetHome pase por el Firewall (0.0.0.0/0 → Firewall IP)
#
# El UDR crea un "túnel lógico": las VMs no pueden salir a Internet
# ni recibir tráfico sin pasar por el Firewall.
# =====================================================================
echo "🌍 Creando IP pública del Firewall..."
if exists_public_ip "$FIREWALL_PUBLIC_IP_NAME"; then
  echo "ℹ️ IP pública del Firewall ya existe, se omite creación."
else
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FIREWALL_PUBLIC_IP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --output none
fi

if exists_firewall; then
  echo "ℹ️ Azure Firewall ya existe, se omite creación."
else
  echo "🔥 Creando Azure Firewall..."
  az network firewall create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FIREWALL_NAME" \
    --location "$LOCATION" \
    --sku "$FIREWALL_SKU" \
    --tier "$FIREWALL_TIER" \
    --output none
fi

echo "🔗 Configurando IP del Firewall en la VNet..."
if exists_firewall_ip_config; then
  echo "ℹ️ IP config del Firewall ya existe, se omite creación."
else
  az network firewall ip-config create \
    --resource-group "$RESOURCE_GROUP" \
    --firewall-name "$FIREWALL_NAME" \
    --name "$FIREWALL_IPCONFIG_NAME" \
    --public-ip-address "$FIREWALL_PUBLIC_IP_NAME" \
    --vnet-name "$VNET_NAME" \
    --output none
fi

# Obtener la IP privada del Firewall dentro de la VNet.
# Esta IP se usa como "next hop" en la UDR para redirigir tráfico.
FIREWALL_PRIVATE_IP=$(az network firewall show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --query "ipConfigurations[0].privateIPAddress" \
  --output tsv)

if [[ -z "$FIREWALL_PRIVATE_IP" ]]; then
  echo "❌ No se pudo obtener IP privada del firewall."
  exit 1
fi

echo "🧭 Creando UDR para forzar tráfico por Firewall..."
if exists_route_table; then
  echo "ℹ️ Route table ya existe, se omite creación."
else
  az network route-table create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$ROUTE_TABLE_NAME" \
    --location "$LOCATION" \
    --disable-bgp-route-propagation true \
    --output none
fi

if exists_route; then
  echo "ℹ️ Ruta por defecto ya existe, se omite creación."
else
  az network route-table route create \
    --resource-group "$RESOURCE_GROUP" \
    --route-table-name "$ROUTE_TABLE_NAME" \
    --name "$ROUTE_NAME_DEFAULT" \
    --address-prefix 0.0.0.0/0 \
    --next-hop-type VirtualAppliance \
    --next-hop-ip-address "$FIREWALL_PRIVATE_IP" \
    --output none
fi

# Asociar la tabla de rutas a la subred workload.
# Esto hace que todas las VMs en SubNetHome usen la UDR
# y envíen su tráfico a través del Firewall.
CURRENT_ROUTE_TABLE_ID=$(az network vnet subnet show \
  --resource-group "$RESOURCE_GROUP" \
  --vnet-name "$VNET_NAME" \
  --name "$SUBNET_WORKLOAD_NAME" \
  --query "routeTable.id" \
  --output tsv 2>/dev/null || true)

if [[ -n "$CURRENT_ROUTE_TABLE_ID" ]]; then
  echo "ℹ️ La subred workload ya tiene route table asociada, se omite actualización."
else
  az network vnet subnet update \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_WORKLOAD_NAME" \
    --route-table "$ROUTE_TABLE_NAME" \
    --output none
fi

# =====================================================================
# FASE 3: FIREWALL POLICY + REGLAS
# =====================================================================
# Estructura jerárquica de la Policy:
#
#   NubeFirewallPolicy
#   └── Default-Connection-Policies (RCG, prioridad 100)
#       ├── DNAT-Inbound (NAT Collection, prioridad 100)
#       │   ├── DNAT-Win-RDP:   *:3389  → WindowsVM:3389
#       │   └── DNAT-Linux-SSH: *:2201  → LinuxVM:22
#       └── Allow-Admin-Web (Network Collection, prioridad 200)
#           ├── Allow-RDP:   * → 10.0.1.0/24:3389
#           ├── Allow-HTTP:  * → 10.0.1.0/24:80
#           ├── Allow-HTTPS: * → 10.0.1.0/24:443
#           └── Allow-SSH:   * → 10.0.1.0/24:22
#
# IMPORTANTE: Azure Firewall Policy y las "classic rule collections"
# NO pueden coexistir. Si el Firewall tiene reglas clásicas, se
# eliminan antes de asociar la Policy.
# =====================================================================
echo "📜 Creando Firewall Policy..."
if exists_firewall_policy; then
  echo "ℹ️ Firewall Policy ya existe, se omite creación."
else
  az network firewall policy create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$POLICY_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --output none
fi

POLICY_ID=$(az network firewall policy show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$POLICY_NAME" \
  --query "id" \
  --output tsv)

# ----- Limpieza de reglas clásicas y asociación de Policy -----
# Si el Firewall aún NO tiene Policy, hay que:
#   1. Eliminar todas las rule collections clásicas (network, nat, application)
#      porque Azure da error "AzureFirewallPolicyAndRuleCollectionsConflict"
#      si coexisten.
#   2. Asociar la Policy al Firewall (operación async con --no-wait)
#   3. Esperar hasta que la asociación se confirme (polling)
echo "🧹 Limpiando rule collections clásicas para evitar conflicto..."
if firewall_has_policy; then
  echo "ℹ️ El Firewall ya tiene policy asociada, se omite limpieza/asociación."
else
  for c in $(az network firewall show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" --query "networkRuleCollections[].name" --output tsv 2>/dev/null); do
    az network firewall network-rule collection delete --resource-group "$RESOURCE_GROUP" --firewall-name "$FIREWALL_NAME" --name "$c" --output none 2>/dev/null || true
  done
  for c in $(az network firewall show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" --query "natRuleCollections[].name" --output tsv 2>/dev/null); do
    az network firewall nat-rule collection delete --resource-group "$RESOURCE_GROUP" --firewall-name "$FIREWALL_NAME" --name "$c" --output none 2>/dev/null || true
  done
  for c in $(az network firewall show --resource-group "$RESOURCE_GROUP" --name "$FIREWALL_NAME" --query "applicationRuleCollections[].name" --output tsv 2>/dev/null); do
    az network firewall application-rule collection delete --resource-group "$RESOURCE_GROUP" --firewall-name "$FIREWALL_NAME" --name "$c" --output none 2>/dev/null || true
  done

  echo "🔗 Asociando Firewall Policy al Firewall..."
  az network firewall update \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FIREWALL_NAME" \
    --firewall-policy "$POLICY_ID" \
    --output none \
    --no-wait

  wait_for_firewall_policy_association
fi

# ----- Obtener IPs necesarias para las reglas -----
# IP privada Linux: puede no existir si la VM Linux no se creó (|| true)
# IP privada Windows: necesaria para la regla DNAT de RDP
# IP pública Firewall: destino de las reglas DNAT (donde llega el tráfico externo)
LINUX_PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$LINUX_VM_NAME" --show-details --query "privateIps" -o tsv 2>/dev/null || true)
WINDOWS_PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$WINDOWS_VM_NAME" --show-details --query "privateIps" -o tsv)
FIREWALL_PUBLIC_IP=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$FIREWALL_PUBLIC_IP_NAME" --query "ipAddress" -o tsv)

# ----- Rule Collection Group (NO destructivo) -----
# El RCG agrupa todas las rule collections. Se crea solo si no existe.
# NUNCA se borra para preservar reglas existentes.
if exists_policy_rcg; then
  echo "ℹ️ Rule Collection Group ya existe, se mantiene."
else
  az network firewall policy rule-collection-group create \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --name "$RCG_NAME" \
    --priority 100 \
    --output none
  wait_for_policy_rcg
fi

# ----- DNAT Collection: redirige puertos externos a VMs internas -----
# La NAT collection se crea con la primera regla (DNAT-Win-RDP).
# Si ya existe, no se recrea. Luego se añaden reglas adicionales.
if exists_policy_collection "$NAT_COLLECTION_NAME"; then
  echo "ℹ️ NAT collection ya existe, se mantiene."
else
  az network firewall policy rule-collection-group collection add-nat-collection \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --name "$NAT_COLLECTION_NAME" \
    --collection-priority 100 \
    --action Dnat \
    --rule-name "DNAT-Win-RDP" \
    --source-addresses "*" \
    --destination-addresses "$FIREWALL_PUBLIC_IP" \
    --destination-ports "$RDP_EXTERNAL_PORT" \
    --ip-protocols TCP \
    --translated-address "$WINDOWS_PRIVATE_IP" \
    --translated-port 3389 \
    --output none
fi

# Esperar a que la collection se propague en Azure antes de añadir reglas.
# El sleep 10 extra es una medida de seguridad adicional contra
# el error "The request is invalid" por consistencia eventual.
wait_for_policy_collection "$NAT_COLLECTION_NAME"
sleep 10

# Verificar y añadir regla DNAT-Win-RDP:
# Redirige Firewall:3389 → WindowsVM:3389 (RDP)
if exists_policy_rule "$NAT_COLLECTION_NAME" "DNAT-Win-RDP"; then
  echo "ℹ️ Regla DNAT-Win-RDP ya existe, se mantiene."
else
  echo "➕ Añadiendo regla DNAT-Win-RDP..."
  az network firewall policy rule-collection-group collection rule add \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --collection-name "$NAT_COLLECTION_NAME" \
    --name "DNAT-Win-RDP" \
    --rule-type NatRule \
    --source-addresses "*" \
    --destination-addresses "$FIREWALL_PUBLIC_IP" \
    --destination-ports "$RDP_EXTERNAL_PORT" \
    --ip-protocols TCP \
    --translated-address "$WINDOWS_PRIVATE_IP" \
    --translated-port 3389 \
    --output none || echo "⚠️ Error al añadir DNAT-Win-RDP (puede que ya exista)."
  sleep 10
fi

# ----- DNAT-Linux-SSH: Redirige Firewall:2201 → LinuxVM:22 (SSH) -----
# Solo se crea si la VM Linux existe (tiene IP privada).
# Se usa puerto 2201 externamente para no colisionar con el 22 estándar.
if [[ -n "$LINUX_PRIVATE_IP" ]]; then
  if exists_policy_rule "$NAT_COLLECTION_NAME" "DNAT-Linux-SSH"; then
    echo "ℹ️ Regla DNAT-Linux-SSH ya existe, se mantiene."
  else
    echo "➕ Añadiendo regla DNAT-Linux-SSH..."
    az network firewall policy rule-collection-group collection rule add \
      --resource-group "$RESOURCE_GROUP" \
      --policy-name "$POLICY_NAME" \
      --rcg-name "$RCG_NAME" \
      --collection-name "$NAT_COLLECTION_NAME" \
      --name "DNAT-Linux-SSH" \
      --rule-type NatRule \
      --source-addresses "*" \
      --destination-addresses "$FIREWALL_PUBLIC_IP" \
      --destination-ports "$SSH_EXTERNAL_PORT" \
      --ip-protocols TCP \
      --translated-address "$LINUX_PRIVATE_IP" \
      --translated-port 22 \
      --output none || echo "⚠️ Error al añadir DNAT-Linux-SSH (puede que ya exista)."
    sleep 10
  fi
fi

# ----- Network Collection: permite tráfico hacia la subred workload -----
# Las reglas Network permiten que el tráfico (ya redirigido por DNAT)
# llegue a la subred 10.0.1.0/24. Sin estas reglas, el Firewall
# bloquearía el tráfico aunque el DNAT lo redirija correctamente.
# La collection se crea con la primera regla (Allow-RDP).
if exists_policy_collection "$NETWORK_COLLECTION_NAME"; then
  echo "ℹ️ Network collection ya existe, se mantiene."
else
  az network firewall policy rule-collection-group collection add-filter-collection \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --name "$NETWORK_COLLECTION_NAME" \
    --collection-priority 200 \
    --action Allow \
    --rule-name "Allow-RDP" \
    --source-addresses "*" \
    --destination-addresses "$SUBNET_WORKLOAD_PREFIX" \
    --destination-ports 3389 \
    --ip-protocols TCP \
    --output none
fi

# Esperar propagación de la Network collection antes de añadir reglas
wait_for_policy_collection "$NETWORK_COLLECTION_NAME"
sleep 10

# Verificar y añadir regla Allow-RDP: permite RDP (3389) hacia la subred
if exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-RDP"; then
  echo "ℹ️ Regla Allow-RDP ya existe, se mantiene."
else
  echo "➕ Añadiendo regla Allow-RDP..."
  az network firewall policy rule-collection-group collection rule add \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --collection-name "$NETWORK_COLLECTION_NAME" \
    --name "Allow-RDP" \
    --rule-type NetworkRule \
    --source-addresses "*" \
    --destination-addresses "$SUBNET_WORKLOAD_PREFIX" \
    --destination-ports 3389 \
    --ip-protocols TCP \
    --output none || echo "⚠️ Error al añadir Allow-RDP (puede que ya exista)."
  sleep 10
fi

# Verificar y añadir regla Allow-HTTP: permite HTTP (80) hacia la subred
if exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-HTTP"; then
  echo "ℹ️ Regla Allow-HTTP ya existe, se mantiene."
else
  echo "➕ Añadiendo regla Allow-HTTP..."
  az network firewall policy rule-collection-group collection rule add \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --collection-name "$NETWORK_COLLECTION_NAME" \
    --name "Allow-HTTP" \
    --rule-type NetworkRule \
    --source-addresses "*" \
    --destination-addresses "$SUBNET_WORKLOAD_PREFIX" \
    --destination-ports 80 \
    --ip-protocols TCP \
    --output none || echo "⚠️ Error al añadir Allow-HTTP (puede que ya exista)."
  sleep 10
fi

# Verificar y añadir regla Allow-HTTPS: permite HTTPS (443) hacia la subred
if exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-HTTPS"; then
  echo "ℹ️ Regla Allow-HTTPS ya existe, se mantiene."
else
  echo "➕ Añadiendo regla Allow-HTTPS..."
  az network firewall policy rule-collection-group collection rule add \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$POLICY_NAME" \
    --rcg-name "$RCG_NAME" \
    --collection-name "$NETWORK_COLLECTION_NAME" \
    --name "Allow-HTTPS" \
    --rule-type NetworkRule \
    --source-addresses "*" \
    --destination-addresses "$SUBNET_WORKLOAD_PREFIX" \
    --destination-ports 443 \
    --ip-protocols TCP \
    --output none || echo "⚠️ Error al añadir Allow-HTTPS (puede que ya exista)."
  sleep 10
fi

# Verificar y añadir regla Allow-SSH: permite SSH (22) hacia la subred
# Solo si la VM Linux existe.
if [[ -n "$LINUX_PRIVATE_IP" ]]; then
  if exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-SSH"; then
    echo "ℹ️ Regla Allow-SSH ya existe, se mantiene."
  else
    echo "➕ Añadiendo regla Allow-SSH..."
    az network firewall policy rule-collection-group collection rule add \
      --resource-group "$RESOURCE_GROUP" \
      --policy-name "$POLICY_NAME" \
      --rcg-name "$RCG_NAME" \
      --collection-name "$NETWORK_COLLECTION_NAME" \
      --name "Allow-SSH" \
      --rule-type NetworkRule \
      --source-addresses "*" \
      --destination-addresses "$SUBNET_WORKLOAD_PREFIX" \
      --destination-ports 22 \
      --ip-protocols TCP \
      --output none || echo "⚠️ Error al añadir Allow-SSH (puede que ya exista)."
    sleep 10
  fi
fi

# =====================================================================
# VERIFICACIÓN FINAL
# =====================================================================
# Muestra las IPs de acceso y verifica que todas las reglas estén
# creadas correctamente en la Firewall Policy.
# =====================================================================
echo ""
echo "✅ Despliegue finalizado"
echo "🌐 Firewall Public IP: $FIREWALL_PUBLIC_IP"
echo "🪟 RDP Windows: $FIREWALL_PUBLIC_IP:$RDP_EXTERNAL_PORT"
echo "🐧 SSH Linux:   $FIREWALL_PUBLIC_IP:$SSH_EXTERNAL_PORT"
echo ""
echo "🔎 Verificación de reglas en Firewall Policy:"
echo "   DNAT-Win-RDP: $(exists_policy_rule "$NAT_COLLECTION_NAME" "DNAT-Win-RDP" && echo OK || echo FALTA)"
echo "   DNAT-Linux-SSH: $(exists_policy_rule "$NAT_COLLECTION_NAME" "DNAT-Linux-SSH" && echo OK || echo FALTA)"
echo "   Allow-RDP: $(exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-RDP" && echo OK || echo FALTA)"
echo "   Allow-HTTP: $(exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-HTTP" && echo OK || echo FALTA)"
echo "   Allow-HTTPS: $(exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-HTTPS" && echo OK || echo FALTA)"
echo "   Allow-SSH: $(exists_policy_rule "$NETWORK_COLLECTION_NAME" "Allow-SSH" && echo OK || echo FALTA)"
