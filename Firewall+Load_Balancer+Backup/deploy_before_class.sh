#!/bin/bash

# =====================================================================
# SCRIPT: deploy_before_class.sh
# DESCRIPCIÓN:
#   Pre-configuración de recursos Azure antes de clase.
#   Despliega la infraestructura base:
#     1) Grupo de recursos: GrupoNube
#     2) Red virtual (VNet) con 4 subredes:
#        - AzureFirewallSubnet (10.0.0.0/26)
#        - AzureFirewallManagementSubnet (10.0.1.0/26)
#        - NubeVpsGroups (10.0.2.0/24)
#        - NubeLoadBalancer (10.0.3.0/24)
#     3) VM Linux con Nginx:
#        - NubeVpsLinux1 en subred NubeVpsGroups
#
# CARACTERÍSTICAS:
#   - Idempotente: no recrea recursos que ya existen
#   - No destructivo: no borra recursos existentes
#   - Log completo de la ejecución
#   - Instala Nginx con página personalizada
#
# PREREQUISITOS:
#   - Azure CLI instalado y autenticado (az login)
#   - Suscripción Azure activa con permisos de Contributor
#   - Ejecutar en Azure Cloud Shell (Bash) o terminal con az CLI
#
# USO:
#   chmod +x deploy_before_class.sh
#   bash deploy_before_class.sh
#
# ⚠️  NO ejecutar con 'source' (si hay error, cierra la sesión).
# =====================================================================

set -euo pipefail

LOG_FILE="$HOME/deploy-before-class.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =====================================================================
# VARIABLES DE CONFIGURACIÓN
# =====================================================================

# --- Grupo de recursos y ubicación ---
RESOURCE_GROUP="GrupoNube"
LOCATION="eastus2"

# --- Red Virtual (VNet) ---
VNET_NAME="NubeVnet"
VNET_PREFIX="10.0.0.0/16"

# --- Subredes ---
SUBNET_FIREWALL_NAME="AzureFirewallSubnet"
SUBNET_FIREWALL_PREFIX="10.0.0.0/26"              # 64 direcciones

SUBNET_FIREWALL_MGMT_NAME="AzureFirewallManagementSubnet"
SUBNET_FIREWALL_MGMT_PREFIX="10.0.1.0/26"         # 64 direcciones

SUBNET_VPS_NAME="NubeVpsGroups"
SUBNET_VPS_PREFIX="10.0.2.0/24"                   # 256 direcciones

SUBNET_LB_NAME="NubeLoadBalancer"
SUBNET_LB_PREFIX="10.0.3.0/24"                    # 256 direcciones

# --- Máquinas Virtuales ---
VM_LINUX1_NAME="NubeVpsLinux1"
VM_LINUX2_NAME="NubeVpsLinux2"
VM_SIZE="Standard_B2s"
LINUX_IMAGE="Ubuntu2204"
ADMIN_USER="azureuser"
ADMIN_PASSWORD="Admin123456."

# --- NSG ---
NSG_NAME="nube-vps-nsg"

echo "🚀 Iniciando pre-configuración de recursos Azure..."
echo "📝 Log en: $LOG_FILE"
az config set extension.use_dynamic_install=yes_without_prompt --output none
az account show --output none

# =====================================================================
# FUNCIONES HELPER DE IDEMPOTENCIA
# =====================================================================

exists_resource_group() {
  [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]]
}

exists_vnet() {
  az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query "name" -o tsv >/dev/null 2>&1
}

exists_subnet() {
  az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_vm() {
  az vm show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_nsg() {
  az network nsg show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# =====================================================================
# FASE 1: GRUPO DE RECURSOS
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 1: GRUPO DE RECURSOS"
echo "═══════════════════════════════════════════════════════════════"

echo "📦 Creando/verificando Resource Group '$RESOURCE_GROUP'..."
if exists_resource_group; then
  echo "  ℹ️  Resource Group '$RESOURCE_GROUP' ya existe, se omite creación."
else
  az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none
  echo "  ✅ Resource Group '$RESOURCE_GROUP' creado en '$LOCATION'."
fi

# =====================================================================
# FASE 2: RED VIRTUAL + SUBREDES
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 2: RED VIRTUAL + SUBREDES"
echo "═══════════════════════════════════════════════════════════════"

echo "🌐 Creando/verificando VNet '$VNET_NAME'..."
if exists_vnet; then
  echo "  ℹ️  VNet '$VNET_NAME' ya existe, se omite creación."
else
  az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "$VNET_PREFIX" \
    --location "$LOCATION" \
    --output none
  echo "  ✅ VNet '$VNET_NAME' creada ($VNET_PREFIX)."
fi

# ----- 2.1.1 AzureFirewallSubnet -----
echo "🔌 Creando/verificando subred '$SUBNET_FIREWALL_NAME'..."
if exists_subnet "$SUBNET_FIREWALL_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_FIREWALL_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_FIREWALL_NAME" \
    --address-prefixes "$SUBNET_FIREWALL_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_FIREWALL_NAME' creada ($SUBNET_FIREWALL_PREFIX) — 64 direcciones."
fi

# ----- 2.1.2 AzureFirewallManagementSubnet -----
echo "🔌 Creando/verificando subred '$SUBNET_FIREWALL_MGMT_NAME'..."
if exists_subnet "$SUBNET_FIREWALL_MGMT_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_FIREWALL_MGMT_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_FIREWALL_MGMT_NAME" \
    --address-prefixes "$SUBNET_FIREWALL_MGMT_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_FIREWALL_MGMT_NAME' creada ($SUBNET_FIREWALL_MGMT_PREFIX) — 64 direcciones."
fi

# ----- 2.1.3 NubeVpsGroups -----
echo "🔌 Creando/verificando subred '$SUBNET_VPS_NAME'..."
if exists_subnet "$SUBNET_VPS_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_VPS_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_VPS_NAME" \
    --address-prefixes "$SUBNET_VPS_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_VPS_NAME' creada ($SUBNET_VPS_PREFIX) — 256 direcciones."
fi

# ----- 2.1.4 NubeLoadBalancer -----
echo "🔌 Creando/verificando subred '$SUBNET_LB_NAME'..."
if exists_subnet "$SUBNET_LB_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_LB_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_LB_NAME" \
    --address-prefixes "$SUBNET_LB_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_LB_NAME' creada ($SUBNET_LB_PREFIX) — 256 direcciones."
fi

echo ""
echo "  📋 Resumen de subredes:"
echo "     ├── $SUBNET_FIREWALL_NAME      → $SUBNET_FIREWALL_PREFIX (64 IPs)"
echo "     ├── $SUBNET_FIREWALL_MGMT_NAME → $SUBNET_FIREWALL_MGMT_PREFIX (64 IPs)"
echo "     ├── $SUBNET_VPS_NAME           → $SUBNET_VPS_PREFIX (256 IPs)"
echo "     └── $SUBNET_LB_NAME            → $SUBNET_LB_PREFIX (256 IPs)"

# =====================================================================
# FASE 3: NSG + MÁQUINA VIRTUAL LINUX
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 3: NSG + MÁQUINA VIRTUAL LINUX"
echo "═══════════════════════════════════════════════════════════════"

# ----- NSG -----
echo "🛡️  Creando/verificando NSG '$NSG_NAME'..."
if exists_nsg "$NSG_NAME"; then
  echo "  ℹ️  NSG '$NSG_NAME' ya existe, se omite creación."
else
  az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --location "$LOCATION" \
    --output none
  echo "  ✅ NSG '$NSG_NAME' creado."
fi

# ----- Reglas del NSG: HTTP (80), SSH (22), RDP (3389) -----
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

az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "Allow-RDP" \
  --priority 300 \
  --access Allow \
  --direction Inbound \
  --protocol TCP \
  --source-address-prefixes "*" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges 3389 \
  --output none 2>/dev/null || true

echo "  ✅ Reglas NSG configuradas (HTTP:80, SSH:22, RDP:3389)."

# ----- VM Linux: NubeVpsLinux1 -----
echo "💻 Creando/verificando VM '$VM_LINUX1_NAME' (Ubuntu 22.04 LTS)..."
if exists_vm "$VM_LINUX1_NAME"; then
  echo "  ℹ️  VM '$VM_LINUX1_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_LINUX1_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD" \
    --authentication-type password \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_VPS_NAME" \
    --nsg "$NSG_NAME" \
    --public-ip-address "" \
    --output none
  echo "  ✅ VM '$VM_LINUX1_NAME' creada en subred '$SUBNET_VPS_NAME'."
fi

# ----- Abrir puertos en la VM -----
echo "🛡️  Abriendo puertos 80, 22 y 3389 en la VM..."
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX1_NAME" --port 80 --priority 1100 --output none 2>/dev/null || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX1_NAME" --port 22 --priority 1200 --output none 2>/dev/null || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX1_NAME" --port 3389 --priority 1300 --output none 2>/dev/null || true
echo "  ✅ Puertos abiertos (HTTP:80, SSH:22, RDP:3389)."

# ----- Instalación de Nginx con página personalizada -----
echo "🌐 Instalando Nginx en '$VM_LINUX1_NAME'..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_LINUX1_NAME" \
  --command-id RunShellScript \
  --scripts '
    #!/bin/bash
    sudo su
    apt-get -y update
    apt-get -y upgrade
    apt-get -y install nginx
    echo "<h1>Hola Mundo desde $(hostname) <strong> Pendiente </strong> </h1>" > /var/www/html/index.html
  ' \
  --output none
echo "  ✅ Nginx instalado con página personalizada en '$VM_LINUX1_NAME'."

# ----- VM Linux: NubeVpsLinux2 -----
echo "💻 Creando/verificando VM '$VM_LINUX2_NAME' (Ubuntu 22.04 LTS)..."
if exists_vm "$VM_LINUX2_NAME"; then
  echo "  ℹ️  VM '$VM_LINUX2_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_LINUX2_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD" \
    --authentication-type password \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_VPS_NAME" \
    --nsg "$NSG_NAME" \
    --public-ip-address "" \
    --output none
  echo "  ✅ VM '$VM_LINUX2_NAME' creada en subred '$SUBNET_VPS_NAME'."
fi

# ----- Abrir puertos en la VM 2 -----
echo "🛡️  Abriendo puertos 80, 22 y 3389 en '$VM_LINUX2_NAME'..."
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX2_NAME" --port 80 --priority 1100 --output none 2>/dev/null || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX2_NAME" --port 22 --priority 1200 --output none 2>/dev/null || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_LINUX2_NAME" --port 3389 --priority 1300 --output none 2>/dev/null || true
echo "  ✅ Puertos abiertos en '$VM_LINUX2_NAME' (HTTP:80, SSH:22, RDP:3389)."

# ----- Instalación de Nginx con página personalizada en VM 2 -----
echo "🌐 Instalando Nginx en '$VM_LINUX2_NAME'..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_LINUX2_NAME" \
  --command-id RunShellScript \
  --scripts '
    #!/bin/bash
    sudo su
    apt-get -y update
    apt-get -y upgrade
    apt-get -y install nginx
    echo "<h1>Hola Mundo desde $(hostname) <strong> Pendiente </strong> </h1>" > /var/www/html/index.html
  ' \
  --output none
echo "  ✅ Nginx instalado con página personalizada en '$VM_LINUX2_NAME'."

# =====================================================================
# VERIFICACIÓN FINAL
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VERIFICACIÓN FINAL"
echo "═══════════════════════════════════════════════════════════════"

# Obtener IPs privadas de las VMs
VM1_PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX1_NAME" \
  --show-details --query "privateIps" -o tsv 2>/dev/null || echo "N/A")
VM2_PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX2_NAME" \
  --show-details --query "privateIps" -o tsv 2>/dev/null || echo "N/A")

echo ""
echo "✅ Pre-configuración finalizada exitosamente"
echo ""
echo "📋 Recursos creados:"
echo "   ├── Resource Group:  $RESOURCE_GROUP ($LOCATION)"
echo "   ├── VNet:            $VNET_NAME ($VNET_PREFIX)"
echo "   │   ├── $SUBNET_FIREWALL_NAME      → $SUBNET_FIREWALL_PREFIX (64 IPs)"
echo "   │   ├── $SUBNET_FIREWALL_MGMT_NAME → $SUBNET_FIREWALL_MGMT_PREFIX (64 IPs)"
echo "   │   ├── $SUBNET_VPS_NAME           → $SUBNET_VPS_PREFIX (256 IPs)"
echo "   │   └── $SUBNET_LB_NAME            → $SUBNET_LB_PREFIX (256 IPs)"
echo "   ├── NSG:             $NSG_NAME (HTTP:80, SSH:22, RDP:3389)"
echo "   ├── VM:              $VM_LINUX1_NAME (Ubuntu 22.04 + Nginx)"
echo "   │                    IP privada: $VM1_PRIVATE_IP"
echo "   └── VM:              $VM_LINUX2_NAME (Ubuntu 22.04 + Nginx)"
echo "                        IP privada: $VM2_PRIVATE_IP"
echo ""
echo "⚠️  Las VMs no tienen IP pública. Para acceder:"
echo "   - Usar Azure Bastion"
echo "   - Conectar desde otra VM en la misma VNet"
echo "   - Configurar un Firewall con regla DNAT"
echo ""
echo "📝 Log completo en: $LOG_FILE"
