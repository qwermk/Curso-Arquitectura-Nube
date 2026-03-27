#!/bin/bash

# =====================================================================
# SCRIPT: deploy_in_class.sh
# DESCRIPCIÓN:
#   Continuación del laboratorio (Fase 2 — En clase).
#   Requiere haber ejecutado deploy_before_class.sh previamente.
#
#   Despliega:
#     4) Load Balancer interno (Standard)
#        - IP frontend en subred NubeLoadBalancer
#        - Backend Pool con NubeVpsLinux1 + NubeVpsLinux2
#        - Regla de balanceo puerto 80
#        - Sondeo de estado TCP:80
#     5) Azure Firewall (Basic)
#        - Política de Firewall
#        - IP pública + IP de administración
#        - Regla DNAT para acceso a las VMs via LB
#     6) Almacén de Recovery Services
#        - Backup de las VMs
#
# FLUJO DE TRÁFICO:
#   Internet → Firewall (DNAT) → Load Balancer → VMs (Nginx)
#
# CARACTERÍSTICAS:
#   - Idempotente: no recrea recursos que ya existen
#   - No destructivo: no borra recursos existentes
#   - Log completo de la ejecución
#
# PREREQUISITOS:
#   - Haber ejecutado deploy_before_class.sh exitosamente
#   - Azure CLI instalado y autenticado (az login)
#   - Suscripción Azure activa con permisos de Contributor
#
# USO:
#   chmod +x deploy_in_class.sh
#   bash deploy_in_class.sh
#
# ⚠️  NO ejecutar con 'source' (si hay error, cierra la sesión).
# =====================================================================

set -euo pipefail

LOG_FILE="$HOME/deploy-in-class.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =====================================================================
# VARIABLES DE CONFIGURACIÓN
# =====================================================================
# Deben coincidir con las de deploy_before_class.sh
# =====================================================================

# --- Grupo de recursos y ubicación ---
RESOURCE_GROUP="GrupoNube"
LOCATION="eastus2"

# --- Red Virtual (VNet) ---
VNET_NAME="NubeVnet"

# --- Subredes (creadas en deploy_before_class.sh) ---
SUBNET_LB_NAME="NubeLoadBalancer"
SUBNET_VPS_NAME="NubeVpsGroups"

# --- Máquinas Virtuales (creadas en deploy_before_class.sh) ---
VM_LINUX1_NAME="NubeVpsLinux1"
VM_LINUX2_NAME="NubeVpsLinux2"

# --- Load Balancer ---
LB_NAME="NubeLoadBalancer"
LB_FRONTEND_IP_NAME="NubeLoadBalancerIp"
LB_BACKEND_POOL_NAME="NubeVpsGroupsback-end"
LB_RULE_NAME="NubeLoadBalancerRuler"
LB_PROBE_NAME="NubeLoadBalancerSondeo"
LB_PORT=80
LB_BACKEND_PORT=80

# --- Firewall ---
FW_NAME="NubeFirewall"
FW_POLICY_NAME="NubeFirewallPolicy"
FW_PUBLIC_IP_NAME="FirewallNubePublicIp"
FW_MGMT_PUBLIC_IP_NAME="FirewallNubePublicAdministratorIp"
FW_DNAT_COLLECTION_NAME="NubeRulerDnatFirewall"
FW_DNAT_RULE_NAME="DnatAccesVps"

# --- Recovery Services ---
RECOVERY_VAULT_NAME="NubeRecoveryServices"

echo "🚀 Iniciando despliegue en clase (Fase 2)..."
echo "📝 Log en: $LOG_FILE"
az config set extension.use_dynamic_install=yes_without_prompt --output none
az config set extension.dynamic_install_allow_preview=true --output none
az account show --output none

# =====================================================================
# VERIFICACIÓN DE PREREQUISITOS
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VERIFICACIÓN DE PREREQUISITOS"
echo "═══════════════════════════════════════════════════════════════"

echo "🔍 Verificando que deploy_before_class.sh se ejecutó..."

# Verificar Resource Group
if [[ "$(az group exists --name "$RESOURCE_GROUP")" != "true" ]]; then
  echo "  ❌ Resource Group '$RESOURCE_GROUP' no existe."
  echo "     Ejecuta primero: bash deploy_before_class.sh"
  exit 1
fi
echo "  ✅ Resource Group '$RESOURCE_GROUP' existe."

# Verificar VNet
if ! az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" --query "name" -o tsv >/dev/null 2>&1; then
  echo "  ❌ VNet '$VNET_NAME' no existe."
  echo "     Ejecuta primero: bash deploy_before_class.sh"
  exit 1
fi
echo "  ✅ VNet '$VNET_NAME' existe."

# Verificar VMs
if ! az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX1_NAME" --query "name" -o tsv >/dev/null 2>&1; then
  echo "  ❌ VM '$VM_LINUX1_NAME' no existe."
  echo "     Ejecuta primero: bash deploy_before_class.sh"
  exit 1
fi
echo "  ✅ VM '$VM_LINUX1_NAME' existe."

if ! az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX2_NAME" --query "name" -o tsv >/dev/null 2>&1; then
  echo "  ❌ VM '$VM_LINUX2_NAME' no existe."
  echo "     Ejecuta primero: bash deploy_before_class.sh"
  exit 1
fi
echo "  ✅ VM '$VM_LINUX2_NAME' existe."

echo "  ✅ Todos los prerequisitos verificados."

# =====================================================================
# FUNCIONES HELPER DE IDEMPOTENCIA
# =====================================================================

exists_lb() {
  az network lb show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_public_ip() {
  az network public-ip show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_firewall() {
  az network firewall show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_fw_policy() {
  az network firewall policy show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_recovery_vault() {
  az resource show -g "$RESOURCE_GROUP" \
    --resource-type "Microsoft.RecoveryServices/vaults" \
    -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

# =====================================================================
# FASE 4: LOAD BALANCER
# =====================================================================
# Crea un Load Balancer interno (Standard) en la subred NubeLoadBalancer:
#   - Frontend IP: NubeLoadBalancerIp (IP privada en la subred)
#   - Backend Pool: NubeVpsGroupsback-end (NubeVpsLinux1 + NubeVpsLinux2)
#   - Health Probe: NubeLoadBalancerSondeo (TCP:80)
#   - Regla: NubeLoadBalancerRuler (puerto 80 → backend 80)
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 4: LOAD BALANCER"
echo "═══════════════════════════════════════════════════════════════"

echo "⚖️  Creando/verificando Load Balancer '$LB_NAME'..."
if exists_lb "$LB_NAME"; then
  echo "  ℹ️  Load Balancer '$LB_NAME' ya existe, se omite creación."
else
  az network lb create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$LB_NAME" \
    --sku Standard \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_LB_NAME" \
    --frontend-ip-name "$LB_FRONTEND_IP_NAME" \
    --backend-pool-name "$LB_BACKEND_POOL_NAME" \
    --location "$LOCATION" \
    --output none
  echo "  ✅ Load Balancer '$LB_NAME' creado (interno, Standard SKU)."
fi

# ----- Sondeo de estado (Health Probe) -----
echo "🩺 Creando/verificando sondeo de estado '$LB_PROBE_NAME'..."
EXISTING_PROBE=$(az network lb probe show \
  -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" \
  -n "$LB_PROBE_NAME" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_PROBE" ]]; then
  echo "  ℹ️  Sondeo '$LB_PROBE_NAME' ya existe."
else
  az network lb probe create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$LB_PROBE_NAME" \
    --protocol Tcp \
    --port "$LB_BACKEND_PORT" \
    --output none
  echo "  ✅ Sondeo '$LB_PROBE_NAME' creado (TCP:$LB_BACKEND_PORT)."
fi

# ----- Regla de balanceo -----
echo "📐 Creando/verificando regla de balanceo '$LB_RULE_NAME'..."
EXISTING_RULE=$(az network lb rule show \
  -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" \
  -n "$LB_RULE_NAME" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_RULE" ]]; then
  echo "  ℹ️  Regla '$LB_RULE_NAME' ya existe."
else
  az network lb rule create \
    --resource-group "$RESOURCE_GROUP" \
    --lb-name "$LB_NAME" \
    --name "$LB_RULE_NAME" \
    --protocol Tcp \
    --frontend-port "$LB_PORT" \
    --backend-port "$LB_BACKEND_PORT" \
    --frontend-ip-name "$LB_FRONTEND_IP_NAME" \
    --backend-pool-name "$LB_BACKEND_POOL_NAME" \
    --probe-name "$LB_PROBE_NAME" \
    --idle-timeout 4 \
    --output none
  echo "  ✅ Regla '$LB_RULE_NAME' creada (puerto $LB_PORT → backend $LB_BACKEND_PORT)."
fi

# ----- Agregar VMs al Backend Pool -----
echo "📦 Agregando VMs al Backend Pool '$LB_BACKEND_POOL_NAME'..."

# Obtener el nombre del NIC de cada VM
VM1_NIC=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX1_NAME" \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | xargs basename)
VM2_NIC=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX2_NAME" \
  --query "networkProfile.networkInterfaces[0].id" -o tsv | xargs basename)

echo "  📋 NIC de $VM_LINUX1_NAME: $VM1_NIC"
echo "  📋 NIC de $VM_LINUX2_NAME: $VM2_NIC"

# Agregar NIC de VM1 al backend pool
echo "  ➕ Agregando '$VM_LINUX1_NAME' al backend pool..."
az network nic ip-config address-pool add \
  --resource-group "$RESOURCE_GROUP" \
  --nic-name "$VM1_NIC" \
  --ip-config-name ipconfig"$VM_LINUX1_NAME" \
  --lb-name "$LB_NAME" \
  --address-pool "$LB_BACKEND_POOL_NAME" \
  --output none 2>/dev/null || true
echo "  ✅ '$VM_LINUX1_NAME' agregada al backend pool."

# Agregar NIC de VM2 al backend pool
echo "  ➕ Agregando '$VM_LINUX2_NAME' al backend pool..."
az network nic ip-config address-pool add \
  --resource-group "$RESOURCE_GROUP" \
  --nic-name "$VM2_NIC" \
  --ip-config-name ipconfig"$VM_LINUX2_NAME" \
  --lb-name "$LB_NAME" \
  --address-pool "$LB_BACKEND_POOL_NAME" \
  --output none 2>/dev/null || true
echo "  ✅ '$VM_LINUX2_NAME' agregada al backend pool."

# Obtener la IP del frontend del LB para usarla en la regla DNAT
LB_FRONTEND_IP=$(az network lb frontend-ip show \
  -g "$RESOURCE_GROUP" --lb-name "$LB_NAME" \
  -n "$LB_FRONTEND_IP_NAME" \
  --query "privateIPAddress" -o tsv)
echo ""
echo "  📋 IP frontend del Load Balancer: $LB_FRONTEND_IP"

# =====================================================================
# FASE 5: FIREWALL
# =====================================================================
# Crea el Azure Firewall con:
#   - Política de Firewall: NubeFirewallPolicy
#   - IP pública: FirewallNubePublicIp
#   - IP de administración: FirewallNubePublicAdministratorIp
#   - Regla DNAT: redirige tráfico HTTP del Firewall al Load Balancer
#
# IMPORTANTE: La creación del Firewall tarda entre 10-15 minutos.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 5: FIREWALL"
echo "═══════════════════════════════════════════════════════════════"

# ----- IPs públicas del Firewall -----
echo "🌍 Creando/verificando IP pública del Firewall..."
if exists_public_ip "$FW_PUBLIC_IP_NAME"; then
  echo "  ℹ️  IP pública '$FW_PUBLIC_IP_NAME' ya existe."
else
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FW_PUBLIC_IP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --output none
  echo "  ✅ IP pública '$FW_PUBLIC_IP_NAME' creada."
fi

echo "🌍 Creando/verificando IP pública de administración del Firewall..."
if exists_public_ip "$FW_MGMT_PUBLIC_IP_NAME"; then
  echo "  ℹ️  IP pública '$FW_MGMT_PUBLIC_IP_NAME' ya existe."
else
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FW_MGMT_PUBLIC_IP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --output none
  echo "  ✅ IP pública '$FW_MGMT_PUBLIC_IP_NAME' creada."
fi

# ----- Política de Firewall -----
echo "📜 Creando/verificando política de Firewall '$FW_POLICY_NAME'..."
if exists_fw_policy "$FW_POLICY_NAME"; then
  echo "  ℹ️  Política '$FW_POLICY_NAME' ya existe."
else
  az network firewall policy create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FW_POLICY_NAME" \
    --location "$LOCATION" \
    --sku Basic \
    --output none
  echo "  ✅ Política '$FW_POLICY_NAME' creada."
fi

# ----- Firewall -----
echo "🔥 Creando/verificando Firewall '$FW_NAME'..."
echo "   ⏳ Esto puede tardar entre 10-15 minutos..."
if exists_firewall "$FW_NAME"; then
  echo "  ℹ️  Firewall '$FW_NAME' ya existe."
else
  az network firewall create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FW_NAME" \
    --location "$LOCATION" \
    --sku AZFW_VNet \
    --tier Basic \
    --vnet-name "$VNET_NAME" \
    --firewall-policy "$FW_POLICY_NAME" \
    --conf-name "FwIpConfig" \
    --public-ip "$FW_PUBLIC_IP_NAME" \
    --m-conf-name "FwMgmtIpConfig" \
    --m-public-ip "$FW_MGMT_PUBLIC_IP_NAME" \
    --output none
  echo "  ✅ Firewall '$FW_NAME' creado."
fi

# Obtener la IP pública del Firewall
FW_PUBLIC_IP=$(az network public-ip show \
  -g "$RESOURCE_GROUP" -n "$FW_PUBLIC_IP_NAME" \
  --query "ipAddress" -o tsv)
echo "  📋 IP pública del Firewall: $FW_PUBLIC_IP"

# ----- Regla DNAT -----
# Redirige el tráfico HTTP (puerto 80) que llega a la IP pública del
# Firewall hacia la IP frontend del Load Balancer interno.
# Flujo: Internet:80 → Firewall (DNAT) → LB Frontend → VMs
echo "📐 Configurando regla DNAT..."

# Crear el Rule Collection Group
echo "  📁 Creando grupo de colección de reglas '$FW_DNAT_COLLECTION_NAME'..."
EXISTING_RCG=$(az network firewall policy rule-collection-group show \
  -g "$RESOURCE_GROUP" --policy-name "$FW_POLICY_NAME" \
  -n "$FW_DNAT_COLLECTION_NAME" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_RCG" ]]; then
  echo "  ℹ️  Grupo '$FW_DNAT_COLLECTION_NAME' ya existe."
else
  az network firewall policy rule-collection-group create \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$FW_POLICY_NAME" \
    --name "$FW_DNAT_COLLECTION_NAME" \
    --priority 100 \
    --output none
  echo "  ✅ Grupo de colección '$FW_DNAT_COLLECTION_NAME' creado."
fi

# Crear la regla DNAT dentro del grupo
echo "  🔀 Creando regla DNAT '$FW_DNAT_RULE_NAME'..."
EXISTING_NAT=$(az network firewall policy rule-collection-group collection list \
  -g "$RESOURCE_GROUP" --policy-name "$FW_POLICY_NAME" \
  --rule-collection-group-name "$FW_DNAT_COLLECTION_NAME" \
  --query "[?name=='$FW_DNAT_RULE_NAME'].name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_NAT" ]]; then
  echo "  ℹ️  Regla DNAT '$FW_DNAT_RULE_NAME' ya existe."
else
  az network firewall policy rule-collection-group collection add-nat-collection \
    --resource-group "$RESOURCE_GROUP" \
    --policy-name "$FW_POLICY_NAME" \
    --rule-collection-group-name "$FW_DNAT_COLLECTION_NAME" \
    --name "$FW_DNAT_RULE_NAME" \
    --collection-priority 100 \
    --action DNAT \
    --rule-name "$FW_DNAT_RULE_NAME" \
    --source-addresses "*" \
    --destination-addresses "$FW_PUBLIC_IP" \
    --destination-ports 80 \
    --translated-address "$LB_FRONTEND_IP" \
    --translated-port 80 \
    --ip-protocols TCP \
    --output none
fi
echo "  ✅ Regla DNAT configurada:"
echo "     Internet:80 → $FW_PUBLIC_IP:80 → $LB_FRONTEND_IP:80 (Load Balancer)"

# =====================================================================
# FASE 6: RECOVERY SERVICES
# =====================================================================
# Crea un almacén de Recovery Services para backup de las VMs.
# NOTA: Recovery Services vault ≠ Backup vault. Son tipos diferentes.
#   - Recovery Services vault (Microsoft.RecoveryServices/vaults) → IaaS VMs
#   - Backup vault (Microsoft.DataProtection/BackupVaults) → Discos, Blobs
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 6: RECOVERY SERVICES"
echo "═══════════════════════════════════════════════════════════════"

# Registrar el proveedor Microsoft.RecoveryServices si no está registrado
echo "📋 Verificando registro del proveedor Microsoft.RecoveryServices..."
RS_STATE=$(az provider show --namespace Microsoft.RecoveryServices --query "registrationState" -o tsv 2>/dev/null || echo "NotRegistered")
if [[ "$RS_STATE" != "Registered" ]]; then
  echo "  ⏳ Registrando proveedor Microsoft.RecoveryServices..."
  az provider register --namespace Microsoft.RecoveryServices --wait --output none
  echo "  ✅ Proveedor registrado."
else
  echo "  ✅ Proveedor ya registrado."
fi

# ----- Eliminar Backup vault (tipo incorrecto) si existe -----
# az backup vault create crea un Backup vault (DataProtection), que NO sirve
# para backup de VMs IaaS. Si existe, hay que eliminarlo primero.
echo "🔍 Verificando si existe un Backup vault con el mismo nombre..."
BV_EXISTS=$(az dataprotection backup-vault show \
  -g "$RESOURCE_GROUP" --vault-name "$RECOVERY_VAULT_NAME" \
  --query "name" -o tsv 2>/dev/null || true)
if [[ -n "$BV_EXISTS" ]]; then
  echo "  ⚠️  Eliminando Backup vault (tipo incorrecto) '$RECOVERY_VAULT_NAME'..."
  az dataprotection backup-vault delete \
    -g "$RESOURCE_GROUP" --vault-name "$RECOVERY_VAULT_NAME" \
    --yes --output none 2>/dev/null || true
  echo "  ✅ Backup vault eliminado."
fi

# ----- Crear Recovery Services vault (tipo correcto para IaaS VMs) -----
echo "🗄️  Creando/verificando almacén de Recovery Services '$RECOVERY_VAULT_NAME'..."
if exists_recovery_vault "$RECOVERY_VAULT_NAME"; then
  echo "  ℹ️  Almacén '$RECOVERY_VAULT_NAME' ya existe."
else
  az resource create \
    --resource-group "$RESOURCE_GROUP" \
    --resource-type "Microsoft.RecoveryServices/vaults" \
    --name "$RECOVERY_VAULT_NAME" \
    --location "$LOCATION" \
    --properties '{"sku":{"name":"Standard"}}' \
    --output none
  echo "  ✅ Almacén '$RECOVERY_VAULT_NAME' creado (Recovery Services vault)."
  echo "  ⏳ Esperando propagación del almacén..."
  sleep 30
fi

# ----- Verificar que DefaultPolicy existe -----
BACKUP_POLICY_NAME="DefaultPolicy"
echo "📜 Verificando directiva de backup '$BACKUP_POLICY_NAME'..."
POLICY_EXISTS=$(az backup policy show \
  --resource-group "$RESOURCE_GROUP" \
  --vault-name "$RECOVERY_VAULT_NAME" \
  --name "$BACKUP_POLICY_NAME" \
  --query "name" -o tsv 2>/dev/null || true)

if [[ -z "$POLICY_EXISTS" ]]; then
  echo "  ⚠️  Directiva '$BACKUP_POLICY_NAME' no encontrada. Listando directivas disponibles..."
  az backup policy list \
    --resource-group "$RESOURCE_GROUP" \
    --vault-name "$RECOVERY_VAULT_NAME" \
    --query "[].name" -o tsv
  echo "  ❌ No se encontró '$BACKUP_POLICY_NAME'. Verifica que el almacén sea de tipo Recovery Services."
  exit 1
fi
echo "  ✅ Directiva '$BACKUP_POLICY_NAME' disponible."

# ----- Habilitar backup de NubeVpsLinux1 -----
# Obtener el resource ID completo de la VM (requerido por az backup)
VM1_ID=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_LINUX1_NAME" --query "id" -o tsv)

echo "🛡️  Habilitando backup de '$VM_LINUX1_NAME' con directiva '$BACKUP_POLICY_NAME'..."

# Verificar si la VM ya está protegida (cualquier estado)
EXISTING_BACKUP=$(az backup item list \
  --resource-group "$RESOURCE_GROUP" \
  --vault-name "$RECOVERY_VAULT_NAME" \
  --backup-management-type AzureIaasVM \
  --query "[?properties.friendlyName=='$VM_LINUX1_NAME'].properties.protectionState" \
  -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_BACKUP" ]]; then
  echo "  ℹ️  VM '$VM_LINUX1_NAME' ya está registrada en el almacén (estado: $EXISTING_BACKUP)."
else
  az backup protection enable-for-vm \
    --resource-group "$RESOURCE_GROUP" \
    --vault-name "$RECOVERY_VAULT_NAME" \
    --vm "$VM1_ID" \
    --policy-name "$BACKUP_POLICY_NAME" \
    --output none
  echo "  ✅ Backup habilitado para '$VM_LINUX1_NAME' con directiva '$BACKUP_POLICY_NAME'."
fi

# =====================================================================
# VERIFICACIÓN FINAL
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VERIFICACIÓN FINAL"
echo "═══════════════════════════════════════════════════════════════"

echo ""
echo "✅ Despliegue en clase finalizado exitosamente"
echo ""
echo "📋 Recursos creados en esta fase:"
echo "   ├── Load Balancer:     $LB_NAME (interno, Standard)"
echo "   │   ├── Frontend IP:   $LB_FRONTEND_IP_NAME → $LB_FRONTEND_IP"
echo "   │   ├── Backend Pool:  $LB_BACKEND_POOL_NAME"
echo "   │   │   ├── $VM_LINUX1_NAME"
echo "   │   │   └── $VM_LINUX2_NAME"
echo "   │   ├── Regla:         $LB_RULE_NAME (puerto $LB_PORT → $LB_BACKEND_PORT)"
echo "   │   └── Sondeo:        $LB_PROBE_NAME (TCP:$LB_BACKEND_PORT)"
echo "   ├── Firewall:          $FW_NAME (Basic)"
echo "   │   ├── Política:      $FW_POLICY_NAME"
echo "   │   ├── IP pública:    $FW_PUBLIC_IP_NAME → $FW_PUBLIC_IP"
echo "   │   ├── IP admin:      $FW_MGMT_PUBLIC_IP_NAME"
echo "   │   └── DNAT:          $FW_DNAT_RULE_NAME"
echo "   │       └── $FW_PUBLIC_IP:80 → $LB_FRONTEND_IP:80"
echo "   └── Recovery Vault:    $RECOVERY_VAULT_NAME"
echo "       └── Backup:        $VM_LINUX1_NAME ($BACKUP_POLICY_NAME)"
echo ""
echo "🌐 Acceso desde Internet:"
echo "   curl http://$FW_PUBLIC_IP"
echo ""
echo "🗺️  Flujo de tráfico:"
echo "   Internet → Firewall ($FW_PUBLIC_IP:80)"
echo "            → DNAT → Load Balancer ($LB_FRONTEND_IP:80)"
echo "            → Backend → $VM_LINUX1_NAME / $VM_LINUX2_NAME"
echo ""
echo "📝 Log completo en: $LOG_FILE"
