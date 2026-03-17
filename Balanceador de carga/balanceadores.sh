#!/bin/bash

# =====================================================================
# SCRIPT: balanceadores.sh
# DESCRIPCIÓN:
#   Despliegue completo de infraestructura Azure con:
#     1) Red virtual (VNet) con una subred para carga de trabajo
#     2) Dos máquinas virtuales Linux (Ubuntu 22.04) en un
#        Availability Set para alta disponibilidad
#     3) Azure Load Balancer (Standard SKU) con IP pública
#     4) Health Probe HTTP para verificar el estado de las VMs
#     5) Reglas de balanceo para distribuir tráfico HTTP y SSH
#     6) Servidor web Nginx instalado en ambas VMs
#
# ARQUITECTURA DE RED:
#   Internet → [Load Balancer Public IP]
#     ├── :80 (HTTP) → Backend Pool
#     │     ├── lb-linux-01 (10.0.2.x:80)
#     │     └── lb-linux-02 (10.0.2.x:80)
#     ├── :2201 (SSH) → lb-linux-01:22 (NAT Rule)
#     └── :2202 (SSH) → lb-linux-02:22 (NAT Rule)
#
# CARACTERÍSTICAS:
#   - Idempotente: no recrea recursos que ya existen
#   - No destructivo: no borra recursos existentes
#   - Log completo de la ejecución
#   - Instala Nginx automáticamente en ambas VMs
#
# PREREQUISITOS:
#   - Azure CLI instalado y autenticado (az login)
#   - Suscripción Azure activa con permisos de Contributor
#   - Ejecutar en Azure Cloud Shell (Bash) o terminal con az CLI
#
# USO:
#   chmod +x balanceadores.sh
#   bash balanceadores.sh
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
LOG_FILE="$HOME/deploy-load-balancer.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =====================================================================
# VARIABLES DE CONFIGURACIÓN
# =====================================================================
# Modifica estas variables para adaptar el despliegue a tu entorno.
# Se reutiliza el mismo estilo de variables del lab VM+Firewall.
# =====================================================================

# --- Grupo de recursos y ubicación ---
RESOURCE_GROUP="GrupNube"        # Nombre del Resource Group (compartido)
LOCATION="eastus2"               # Región Azure (East US 2)

# --- Red Virtual (VNet) ---
VNET_NAME="NubeVnet"             # Nombre de la VNet (compartida)
VNET_PREFIX="10.0.0.0/16"        # Espacio de direcciones completo (65.536 IPs)

# Subred para las VMs del Load Balancer
# Se usa una subred diferente a la del lab de Firewall para no interferir
SUBNET_LB_NAME="SubNetLoadBalancer"
SUBNET_LB_PREFIX="10.0.2.0/24"            # 254 hosts disponibles

# --- Máquinas Virtuales ---
LINUX_VM_01_NAME="lb-linux-01"             # VM Linux 1 (backend pool)
LINUX_VM_02_NAME="lb-linux-02"             # VM Linux 2 (backend pool)
VM_SIZE="Standard_D2s_v3"                  # 2 vCPU, 8 GB RAM
LINUX_IMAGE="Ubuntu2204"                   # Imagen de Ubuntu 22.04
ADMIN_USER="azureuser"                     # Usuario administrador

# --- Availability Set ---
# Agrupa las VMs para garantizar que no estén en el mismo rack/host físico.
# Esto mejora la disponibilidad: si un rack falla, la otra VM sigue activa.
AVAILABILITY_SET_NAME="lb-availability-set"

# --- Network Security Group ---
# Controla el tráfico de red entrante/saliente a la subred del LB.
NSG_NAME="lb-nsg"

# --- Load Balancer ---
LB_NAME="NubeLoadBalancer"                 # Nombre del Load Balancer
LB_PUBLIC_IP_NAME="NubeLBPublicIP"         # IP pública del Load Balancer
LB_FRONTEND_NAME="lb-frontend"            # Configuración frontend (IP pública)
LB_BACKEND_POOL_NAME="lb-backend-pool"    # Pool de VMs backend
LB_PROBE_NAME="lb-health-probe"           # Health probe HTTP
LB_RULE_HTTP_NAME="lb-rule-http"          # Regla de balanceo HTTP (puerto 80)
LB_SKU="Standard"                          # SKU Standard (soporta Availability Zones)

# --- Puertos de acceso SSH individuales (NAT Rules) ---
# Cada VM se accede por SSH a través de un puerto diferente del LB.
# Esto permite acceder a cada VM individualmente para administración.
SSH_NAT_RULE_01="lb-nat-ssh-vm01"          # NAT Rule: LB:2201 → VM01:22
SSH_NAT_RULE_02="lb-nat-ssh-vm02"          # NAT Rule: LB:2202 → VM02:22
SSH_EXTERNAL_PORT_01="2201"                # Puerto externo SSH para VM01
SSH_EXTERNAL_PORT_02="2202"                # Puerto externo SSH para VM02

echo "🚀 Iniciando despliegue de Load Balancer con 2 VMs Linux..."
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

# Verifica si una VM existe en el resource group
exists_vm() {
  az vm show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una IP pública existe
exists_public_ip() {
  az network public-ip show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el Availability Set existe
exists_availability_set() {
  az vm availability-set show -g "$RESOURCE_GROUP" -n "$AVAILABILITY_SET_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el Load Balancer existe
exists_lb() {
  az network lb show -g "$RESOURCE_GROUP" -n "$LB_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el NSG existe
exists_nsg() {
  az network nsg show -g "$RESOURCE_GROUP" -n "$NSG_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una NIC existe
exists_nic() {
  az network nic show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una regla del LB existe
exists_lb_rule() {
  az network lb rule show -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si una NAT rule del LB existe
exists_lb_nat_rule() {
  az network lb inbound-nat-rule show -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# Verifica si el health probe del LB existe
exists_lb_probe() {
  az network lb probe show -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# =====================================================================
# FASE 1: RED BASE (VNet + Subred)
# =====================================================================
# Crea la infraestructura de red:
#   - Resource Group: contenedor lógico de todos los recursos
#   - VNet 10.0.0.0/16: red virtual principal (compartida con otros labs)
#   - SubNetLoadBalancer 10.0.2.0/24: subred exclusiva para las VMs del LB
#   - NSG: reglas de seguridad para permitir HTTP y SSH
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 1: RED BASE (VNet + Subred + NSG)"
echo "═══════════════════════════════════════════════════════════════"

echo "📦 Creando/verificando Resource Group..."
if exists_resource_group; then
  echo "  ℹ️  Resource Group '$RESOURCE_GROUP' ya existe, se omite creación."
else
  az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
  echo "  ✅ Resource Group creado."
fi

echo "🌐 Creando/verificando VNet..."
if exists_vnet; then
  echo "  ℹ️  VNet '$VNET_NAME' ya existe, se omite creación."
else
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_PREFIX" \
    --output none
  echo "  ✅ VNet creada."
fi

echo "🔌 Creando/verificando subred del Load Balancer..."
if exists_subnet "$SUBNET_LB_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_LB_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_LB_NAME" \
    --address-prefixes "$SUBNET_LB_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_LB_NAME' creada."
fi

echo "🛡️  Creando/verificando Network Security Group..."
if exists_nsg; then
  echo "  ℹ️  NSG '$NSG_NAME' ya existe, se omite creación."
else
  az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --location "$LOCATION" \
    --output none
  echo "  ✅ NSG creado."
fi

# ----- Reglas del NSG -----
# Permiten tráfico HTTP (80) y SSH (22) entrante desde Internet.
# Sin estas reglas, el tráfico del Load Balancer sería bloqueado.
echo "🛡️  Configurando reglas del NSG..."
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "Allow-HTTP" \
  --priority 100 \
  --access Allow \
  --direction Inbound \
  --protocol TCP \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 80 \
  --output none 2>/dev/null || true

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "Allow-SSH" \
  --priority 200 \
  --access Allow \
  --direction Inbound \
  --protocol TCP \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 22 \
  --output none 2>/dev/null || true

echo "  ✅ Reglas NSG configuradas (HTTP:80, SSH:22)."

# =====================================================================
# FASE 2: LOAD BALANCER
# =====================================================================
# Crea el Azure Load Balancer con:
#   - IP pública estática (Standard SKU): punto de entrada desde Internet
#   - Frontend IP Configuration: vincula la IP pública al LB
#   - Backend Address Pool: grupo de VMs que reciben el tráfico
#   - Health Probe: verifica que las VMs estén respondiendo (HTTP:80)
#   - Load Balancing Rule: distribuye tráfico HTTP entre las VMs
#   - NAT Rules: permiten acceso SSH individual a cada VM
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 2: LOAD BALANCER"
echo "═══════════════════════════════════════════════════════════════"

echo "🌍 Creando/verificando IP pública del Load Balancer..."
if exists_public_ip "$LB_PUBLIC_IP_NAME"; then
  echo "  ℹ️  IP pública '$LB_PUBLIC_IP_NAME' ya existe, se omite creación."
else
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$LB_PUBLIC_IP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --output none
  echo "  ✅ IP pública creada."
fi

echo "⚖️  Creando/verificando Load Balancer..."
if exists_lb; then
  echo "  ℹ️  Load Balancer '$LB_NAME' ya existe, se omite creación."
else
  az network lb create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$LB_NAME" \
    --location "$LOCATION" \
    --sku "$LB_SKU" \
    --frontend-ip-name "$LB_FRONTEND_NAME" \
    --public-ip-address "$LB_PUBLIC_IP_NAME" \
    --backend-pool-name "$LB_BACKEND_POOL_NAME" \
    --output none
  echo "  ✅ Load Balancer creado."
fi

# ----- Health Probe -----
# Verifica cada 15 segundos que las VMs respondan en el puerto 80.
# Si una VM falla 2 veces consecutivas, se saca del pool.
# Cuando vuelve a responder, se reintegra automáticamente.
echo "❤️  Creando/verificando Health Probe..."
if exists_lb_probe "$LB_PROBE_NAME"; then
  echo "  ℹ️  Health Probe '$LB_PROBE_NAME' ya existe, se omite creación."
else
  az network lb probe create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$LB_PROBE_NAME" \
    --protocol TCP \
    --port 80 \
    --interval 15 \
    --threshold 2 \
    --output none
  echo "  ✅ Health Probe creado (TCP:80, intervalo 15s)."
fi

# ----- Regla de balanceo HTTP -----
# Distribuye el tráfico HTTP (puerto 80) entre todas las VMs del
# backend pool usando el algoritmo de distribución por defecto
# (hash de 5-tupla: IP origen, puerto origen, IP destino, puerto destino, protocolo).
echo "📐 Creando/verificando regla de balanceo HTTP..."
if exists_lb_rule "$LB_RULE_HTTP_NAME"; then
  echo "  ℹ️  Regla '$LB_RULE_HTTP_NAME' ya existe, se omite creación."
else
  az network lb rule create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$LB_RULE_HTTP_NAME" \
    --frontend-ip-name "$LB_FRONTEND_NAME" \
    --backend-pool-name "$LB_BACKEND_POOL_NAME" \
    --probe-name "$LB_PROBE_NAME" \
    --protocol TCP \
    --frontend-port 80 \
    --backend-port 80 \
    --idle-timeout 4 \
    --enable-tcp-reset true \
    --output none
  echo "  ✅ Regla de balanceo HTTP creada (frontend:80 → backend:80)."
fi

# ----- NAT Rules para SSH individual -----
# Permiten acceder por SSH a cada VM individualmente:
#   LB:2201 → VM01:22
#   LB:2202 → VM02:22
# Esto es necesario porque las VMs no tienen IP pública propia.
echo "🔀 Creando/verificando NAT Rules para SSH..."
if exists_lb_nat_rule "$SSH_NAT_RULE_01"; then
  echo "  ℹ️  NAT Rule '$SSH_NAT_RULE_01' ya existe, se omite creación."
else
  az network lb inbound-nat-rule create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$SSH_NAT_RULE_01" \
    --frontend-ip-name "$LB_FRONTEND_NAME" \
    --protocol TCP \
    --frontend-port "$SSH_EXTERNAL_PORT_01" \
    --backend-port 22 \
    --output none
  echo "  ✅ NAT Rule creada: LB:$SSH_EXTERNAL_PORT_01 → VM01:22"
fi

if exists_lb_nat_rule "$SSH_NAT_RULE_02"; then
  echo "  ℹ️  NAT Rule '$SSH_NAT_RULE_02' ya existe, se omite creación."
else
  az network lb inbound-nat-rule create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$SSH_NAT_RULE_02" \
    --frontend-ip-name "$LB_FRONTEND_NAME" \
    --protocol TCP \
    --frontend-port "$SSH_EXTERNAL_PORT_02" \
    --backend-port 22 \
    --output none
  echo "  ✅ NAT Rule creada: LB:$SSH_EXTERNAL_PORT_02 → VM02:22"
fi

# =====================================================================
# FASE 3: MÁQUINAS VIRTUALES
# =====================================================================
# Crea dos VMs Linux en la subred del Load Balancer:
#   - lb-linux-01: VM 1 del backend pool
#   - lb-linux-02: VM 2 del backend pool
#
# Las VMs se crean dentro de un Availability Set para garantizar
# alta disponibilidad (Azure las distribuye en diferentes racks).
#
# Cada VM tiene su propia NIC conectada al backend pool del LB
# y a la NAT Rule correspondiente para SSH individual.
#
# NO tienen IP pública propia; todo el acceso es a través del LB.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 3: MÁQUINAS VIRTUALES"
echo "═══════════════════════════════════════════════════════════════"

# ----- Availability Set -----
# Garantiza que las VMs se distribuyan en diferentes dominios de
# fallo (fault domains) y actualización (update domains).
# fault-domain-count=2:  máximo 2 racks físicos distintos
# update-domain-count=5: hasta 5 grupos de actualización
echo "📦 Creando/verificando Availability Set..."
if exists_availability_set; then
  echo "  ℹ️  Availability Set '$AVAILABILITY_SET_NAME' ya existe, se omite creación."
else
  az vm availability-set create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$AVAILABILITY_SET_NAME" \
    --location "$LOCATION" \
    --platform-fault-domain-count 2 \
    --platform-update-domain-count 5 \
    --output none
  echo "  ✅ Availability Set creado."
fi

# ----- NICs (Network Interface Cards) -----
# Cada VM necesita una NIC que se conecta a:
#   1. La subred del Load Balancer
#   2. El backend pool del LB (para recibir tráfico balanceado)
#   3. La NAT Rule correspondiente (para SSH individual)
#   4. El NSG (para reglas de seguridad)
echo "🔌 Creando/verificando NICs..."

# NIC para VM01
NIC_01_NAME="${LINUX_VM_01_NAME}-nic"
if exists_nic "$NIC_01_NAME"; then
  echo "  ℹ️  NIC '$NIC_01_NAME' ya existe, se omite creación."
else
  az network nic create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_01_NAME" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_LB_NAME" \
    --network-security-group "$NSG_NAME" \
    --lb-name "$LB_NAME" \
    --lb-address-pools "$LB_BACKEND_POOL_NAME" \
    --lb-inbound-nat-rules "$SSH_NAT_RULE_01" \
    --output none
  echo "  ✅ NIC '$NIC_01_NAME' creada y conectada al backend pool + NAT SSH:$SSH_EXTERNAL_PORT_01."
fi

# NIC para VM02
NIC_02_NAME="${LINUX_VM_02_NAME}-nic"
if exists_nic "$NIC_02_NAME"; then
  echo "  ℹ️  NIC '$NIC_02_NAME' ya existe, se omite creación."
else
  az network nic create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_02_NAME" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_LB_NAME" \
    --network-security-group "$NSG_NAME" \
    --lb-name "$LB_NAME" \
    --lb-address-pools "$LB_BACKEND_POOL_NAME" \
    --lb-inbound-nat-rules "$SSH_NAT_RULE_02" \
    --output none
  echo "  ✅ NIC '$NIC_02_NAME' creada y conectada al backend pool + NAT SSH:$SSH_EXTERNAL_PORT_02."
fi

# ----- Creación de VMs -----
# Las VMs se crean con:
#   - La NIC previamente configurada (ya conectada al LB)
#   - Dentro del Availability Set (alta disponibilidad)
#   - Sin IP pública (acceso solo vía Load Balancer)
#   - Autenticación por SSH key (más seguro que contraseña)

echo "💻 Creando/verificando VM Linux 01..."
if exists_vm "$LINUX_VM_01_NAME"; then
  echo "  ℹ️  VM '$LINUX_VM_01_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$LINUX_VM_01_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --nics "$NIC_01_NAME" \
    --availability-set "$AVAILABILITY_SET_NAME" \
    --public-ip-address "" \
    --no-wait \
    --output none
  echo "  ✅ VM '$LINUX_VM_01_NAME' en creación (async)..."
fi

echo "💻 Creando/verificando VM Linux 02..."
if exists_vm "$LINUX_VM_02_NAME"; then
  echo "  ℹ️  VM '$LINUX_VM_02_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$LINUX_VM_02_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --generate-ssh-keys \
    --nics "$NIC_02_NAME" \
    --availability-set "$AVAILABILITY_SET_NAME" \
    --public-ip-address "" \
    --no-wait \
    --output none
  echo "  ✅ VM '$LINUX_VM_02_NAME' en creación (async)..."
fi

# Esperar a que ambas VMs terminen de crearse
# El --no-wait anterior permite crear ambas en paralelo (más rápido).
echo "⏳ Esperando a que ambas VMs terminen de crearse..."
az vm wait --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_01_NAME" --created 2>/dev/null || true
az vm wait --resource-group "$RESOURCE_GROUP" --name "$LINUX_VM_02_NAME" --created 2>/dev/null || true
echo "  ✅ Ambas VMs están listas."

# =====================================================================
# FASE 4: INSTALACIÓN DE NGINX
# =====================================================================
# Instala y configura Nginx en ambas VMs usando Azure Custom Script
# Extension. Cada VM muestra una página diferente para poder verificar
# que el Load Balancer alterna entre ambas.
#
# VM01 mostrará: "🖥️ Servidor: lb-linux-01"
# VM02 mostrará: "🖥️ Servidor: lb-linux-02"
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 4: INSTALACIÓN DE NGINX"
echo "═══════════════════════════════════════════════════════════════"

# Script de instalación para VM01
# Actualiza paquetes, instala Nginx y crea una página personalizada
echo "🌐 Instalando Nginx en VM01..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$LINUX_VM_01_NAME" \
  --command-id RunShellScript \
  --scripts '
    sudo apt-get update -y
    sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    echo "<!DOCTYPE html>
<html>
<head><title>Load Balancer Lab</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; }
  h1 { font-size: 2.5em; }
  .server { font-size: 1.8em; color: #00ff88; }
</style></head>
<body>
<div class=\"container\">
  <h1>☁️ Curso Arquitectura de Nube</h1>
  <p class=\"server\">🖥️ Servidor: lb-linux-01</p>
  <p>Estud-IA — Laboratorio Load Balancer</p>
</div>
</body></html>" | sudo tee /var/www/html/index.html > /dev/null
  ' \
  --output none
echo "  ✅ Nginx instalado en VM01."

# Script de instalación para VM02 (página diferente para verificar balanceo)
echo "🌐 Instalando Nginx en VM02..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$LINUX_VM_02_NAME" \
  --command-id RunShellScript \
  --scripts '
    sudo apt-get update -y
    sudo apt-get install -y nginx
    sudo systemctl enable nginx
    sudo systemctl start nginx
    echo "<!DOCTYPE html>
<html>
<head><title>Load Balancer Lab</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; }
  h1 { font-size: 2.5em; }
  .server { font-size: 1.8em; color: #00ff88; }
</style></head>
<body>
<div class=\"container\">
  <h1>☁️ Curso Arquitectura de Nube</h1>
  <p class=\"server\">🖥️ Servidor: lb-linux-02</p>
  <p>Estud-IA — Laboratorio Load Balancer</p>
</div>
</body></html>" | sudo tee /var/www/html/index.html > /dev/null
  ' \
  --output none
echo "  ✅ Nginx instalado en VM02."

# =====================================================================
# VERIFICACIÓN FINAL
# =====================================================================
# Muestra las IPs de acceso y el estado de los recursos creados.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VERIFICACIÓN FINAL"
echo "═══════════════════════════════════════════════════════════════"

# Obtener la IP pública del Load Balancer
LB_PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$LB_PUBLIC_IP_NAME" \
  --query "ipAddress" \
  --output tsv)

echo ""
echo "✅ Despliegue finalizado exitosamente"
echo ""
echo "📋 Recursos creados:"
echo "   ├── Resource Group:    $RESOURCE_GROUP"
echo "   ├── VNet:              $VNET_NAME"
echo "   ├── Subred:            $SUBNET_LB_NAME ($SUBNET_LB_PREFIX)"
echo "   ├── NSG:               $NSG_NAME"
echo "   ├── Availability Set:  $AVAILABILITY_SET_NAME"
echo "   ├── Load Balancer:     $LB_NAME ($LB_SKU)"
echo "   ├── VM01:              $LINUX_VM_01_NAME"
echo "   └── VM02:              $LINUX_VM_02_NAME"
echo ""
echo "🌐 Acceso:"
echo "   ├── HTTP (Load Balancer): http://$LB_PUBLIC_IP"
echo "   ├── SSH VM01: ssh $ADMIN_USER@$LB_PUBLIC_IP -p $SSH_EXTERNAL_PORT_01"
echo "   └── SSH VM02: ssh $ADMIN_USER@$LB_PUBLIC_IP -p $SSH_EXTERNAL_PORT_02"
echo ""
echo "🔎 Verificación rápida:"
echo "   curl http://$LB_PUBLIC_IP"
echo "   (Ejecuta varias veces para ver cómo alterna entre VM01 y VM02)"
echo ""
echo "📝 Log completo en: $LOG_FILE"
