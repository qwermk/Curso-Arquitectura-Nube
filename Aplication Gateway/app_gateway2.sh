#!/bin/bash

# =====================================================================
# SCRIPT: app_gateway2.sh
# DESCRIPCIÓN:
#   Despliegue completo de Azure Application Gateway con:
#     1) Red virtual (VNet) con dos subredes
#        - SubnetAppGateway: subred dedicada del Application Gateway
#        - SubNetBackendPool: subred de las VMs backend
#     2) Dos máquinas virtuales Linux (Ubuntu 22.04) con Nginx:
#        - VmImagenes: sirve contenido de imágenes
#        - VmVideo: sirve contenido de videos
#     3) Application Gateway (Standard V2) con:
#        - Frontend con IP pública
#        - Dos Backend Pools (ImagesPool, VideosPool)
#        - Reglas de enrutamiento basadas en path (URL Path Map)
#        - /imagenes/* → ImagesPool (VmImagenes)
#        - /videos/*   → VideosPool (VmVideo)
#
# ARQUITECTURA:
#   Internet → [App Gateway Public IP] → Application Gateway
#     ├── /imagenes/* → ImagesPool → VmImagenes (10.0.4.x:80)
#     └── /videos/*   → VideosPool → VmVideo    (10.0.4.x:80)
#     └── /* (default) → ImagesPool (destino por defecto)
#
# CARACTERÍSTICAS:
#   - Idempotente: no recrea recursos que ya existen
#   - No destructivo: no borra recursos existentes
#   - Log completo de la ejecución
#   - Instala Nginx con páginas personalizadas en cada VM
#
# PREREQUISITOS:
#   - Azure CLI instalado y autenticado (az login)
#   - Suscripción Azure activa con permisos de Contributor
#   - Ejecutar en Azure Cloud Shell (Bash) o terminal con az CLI
#
# USO:
#   chmod +x app_gateway2.sh
#   bash app_gateway2.sh
#
# ⚠️  NO ejecutar con 'source' (si hay error, cierra la sesión).
# =====================================================================

# Modo estricto de Bash:
#   -e: salir inmediatamente si un comando falla
#   -u: error si se usa una variable no definida
#   -o pipefail: el código de salida de un pipe es el del último comando que falle
set -euo pipefail

# Archivo de log: registra toda la salida (stdout + stderr)
LOG_FILE="$HOME/deploy-app-gateway2.log"
exec > >(tee -a "$LOG_FILE") 2>&1

# =====================================================================
# VARIABLES DE CONFIGURACIÓN
# =====================================================================
# Modifica estas variables para adaptar el despliegue a tu entorno.
# =====================================================================

# --- Grupo de recursos y ubicación ---
RESOURCE_GROUP="GrupoNube"       # Nombre del Resource Group
LOCATION="eastus2"               # Región Azure (East US 2)

# --- Red Virtual (VNet) ---
VNET_NAME="NubeVnet"             # Nombre de la VNet
VNET_PREFIX="10.0.0.0/16"        # Espacio de direcciones completo (65.536 IPs)

# Subred dedicada del Application Gateway
# Azure Application Gateway REQUIERE su propia subred exclusiva.
SUBNET_APPGW_NAME="SubnetAppGateway"
SUBNET_APPGW_PREFIX="10.0.3.0/24"         # 254 hosts disponibles

# Subred para las VMs backend (donde se alojan los servidores web)
SUBNET_BACKEND_NAME="SubNetBackendPool"
SUBNET_BACKEND_PREFIX="10.0.4.0/24"       # 254 hosts disponibles

# --- Máquinas Virtuales ---
VM_IMAGENES_NAME="VmImagenes"              # VM que sirve contenido de imágenes
VM_VIDEO_NAME="VmVideo"                    # VM que sirve contenido de videos
VM_SIZE="Standard_B2s"                     # 2 vCPU, 4 GB RAM (suficiente para Linux + Nginx)
LINUX_IMAGE="Ubuntu2204"                   # Imagen de Ubuntu Server 22.04 LTS
ADMIN_USER="azureuser"                     # Usuario administrador
ADMIN_PASSWORD="Admin123456."              # Contraseña de administrador (cambiar en producción)

# --- Network Security Group ---
NSG_NAME="appgw-backend-nsg"               # NSG para la subred backend

# --- Application Gateway ---
APPGW_NAME="NubeAppGateway"                # Nombre del Application Gateway
APPGW_PUBLIC_IP_NAME="NubeAppGwPublicIP"   # IP pública del App Gateway
APPGW_SKU="Standard_v2"                    # SKU: Standard V2 (recomendado)
APPGW_TIER="Standard_v2"                   # Tier: Standard V2

# --- Backend Pools ---
BACKEND_POOL_IMAGES="ImagesPool"           # Pool para el servidor de imágenes
BACKEND_POOL_VIDEOS="VideosPool"           # Pool para el servidor de videos

# --- Configuración de Backend (HTTP Settings) ---
BACKEND_SETTINGS_NAME="Settings1"          # Configuración de backend HTTP

# --- Listener y Reglas ---
LISTENER_NAME="listener1"                  # Agente de escucha HTTP:80
ROUTING_RULE_NAME="RoutingRule1"           # Regla de enrutamiento principal
URL_PATH_MAP_NAME="urlPathMap1"            # Mapa de rutas URL

echo "🚀 Iniciando despliegue de Application Gateway (Linux + Nginx)..."
echo "📝 Log en: $LOG_FILE"
az config set extension.use_dynamic_install=yes_without_prompt --output none
az account show --output none

# =====================================================================
# FUNCIONES HELPER DE IDEMPOTENCIA
# =====================================================================
# Cada función verifica si un recurso Azure ya existe.
# Retorna 0 (true) si existe, 1 (false) si no.
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

exists_public_ip() {
  az network public-ip show -g "$RESOURCE_GROUP" -n "$1" --query "name" -o tsv >/dev/null 2>&1
}

exists_nsg() {
  az network nsg show -g "$RESOURCE_GROUP" -n "$NSG_NAME" --query "name" -o tsv >/dev/null 2>&1
}

exists_appgw() {
  az network application-gateway show -g "$RESOURCE_GROUP" -n "$APPGW_NAME" --query "name" -o tsv >/dev/null 2>&1
}

# =====================================================================
# FASE 1: RED BASE (VNet + Subredes + NSG)
# =====================================================================
# Crea la infraestructura de red:
#   - Resource Group: contenedor lógico de todos los recursos
#   - VNet 10.0.0.0/16: red virtual principal
#   - SubnetAppGateway 10.0.3.0/24: subred exclusiva del App Gateway
#   - SubNetBackendPool 10.0.4.0/24: subred para las VMs backend
#   - NSG: reglas de seguridad para el tráfico HTTP
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 1: RED BASE (VNet + Subredes + NSG)"
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

echo "🔌 Creando/verificando subred del Application Gateway..."
if exists_subnet "$SUBNET_APPGW_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_APPGW_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_APPGW_NAME" \
    --address-prefixes "$SUBNET_APPGW_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_APPGW_NAME' creada ($SUBNET_APPGW_PREFIX)."
fi

echo "🔌 Creando/verificando subred del Backend Pool..."
if exists_subnet "$SUBNET_BACKEND_NAME"; then
  echo "  ℹ️  Subred '$SUBNET_BACKEND_NAME' ya existe, se omite creación."
else
  az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_BACKEND_NAME" \
    --address-prefixes "$SUBNET_BACKEND_PREFIX" \
    --output none
  echo "  ✅ Subred '$SUBNET_BACKEND_NAME' creada ($SUBNET_BACKEND_PREFIX)."
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
# Permiten tráfico HTTP (80) y SSH (22) entrante.
# También se permite el rango 65200-65535 requerido por App Gateway V2.
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

# Regla OBLIGATORIA para Application Gateway V2:
# Azure requiere que los puertos 65200-65535 estén abiertos en la
# subred del App Gateway para los health probes de infraestructura.
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name "Allow-AppGw-Health" \
  --priority 300 \
  --access Allow \
  --direction Inbound \
  --protocol TCP \
  --source-address-prefixes "GatewayManager" \
  --source-port-ranges "*" \
  --destination-address-prefixes "*" \
  --destination-port-ranges "65200-65535" \
  --output none 2>/dev/null || true

echo "  ✅ Reglas NSG configuradas (HTTP:80, SSH:22, AppGw Health:65200-65535)."

# =====================================================================
# FASE 2: MÁQUINAS VIRTUALES
# =====================================================================
# Crea dos VMs Ubuntu 22.04 LTS en la subred SubNetBackendPool:
#   - VmImagenes: servidor de contenido de imágenes
#   - VmVideo: servidor de contenido de videos
#
# Ambas VMs abren el puerto 80 para recibir tráfico HTTP
# del Application Gateway.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 2: MÁQUINAS VIRTUALES"
echo "═══════════════════════════════════════════════════════════════"

echo "💻 Creando/verificando VM Imagenes (Ubuntu 22.04 LTS)..."
if exists_vm "$VM_IMAGENES_NAME"; then
  echo "  ℹ️  VM '$VM_IMAGENES_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_IMAGENES_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD" \
    --authentication-type password \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_BACKEND_NAME" \
    --nsg "$NSG_NAME" \
    --public-ip-address "" \
    --no-wait \
    --output none
  echo "  ✅ VM '$VM_IMAGENES_NAME' en creación (async)..."
fi

echo "💻 Creando/verificando VM Video (Ubuntu 22.04 LTS)..."
if exists_vm "$VM_VIDEO_NAME"; then
  echo "  ℹ️  VM '$VM_VIDEO_NAME' ya existe, se omite creación."
else
  az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_VIDEO_NAME" \
    --location "$LOCATION" \
    --image "$LINUX_IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --admin-password "$ADMIN_PASSWORD" \
    --authentication-type password \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_BACKEND_NAME" \
    --nsg "$NSG_NAME" \
    --public-ip-address "" \
    --no-wait \
    --output none
  echo "  ✅ VM '$VM_VIDEO_NAME' en creación (async)..."
fi

# Esperar a que ambas VMs terminen de crearse
echo "⏳ Esperando a que ambas VMs terminen de crearse..."
az vm wait --resource-group "$RESOURCE_GROUP" --name "$VM_IMAGENES_NAME" --created 2>/dev/null || true
az vm wait --resource-group "$RESOURCE_GROUP" --name "$VM_VIDEO_NAME" --created 2>/dev/null || true
echo "  ✅ Ambas VMs están listas."

# ----- Apertura de puertos en NSG de las VMs -----
# Abre el puerto 80 en las VMs para que el Application Gateway
# pueda enviarles tráfico HTTP.
echo "🛡️  Abriendo puerto 80 en las VMs..."
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_IMAGENES_NAME" --port 80 --priority 1100 --output none || true
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_VIDEO_NAME" --port 80 --priority 1100 --output none || true
echo "  ✅ Puerto 80 abierto en ambas VMs."

# =====================================================================
# FASE 3: INSTALACIÓN DE NGINX
# =====================================================================
# Instala Nginx en ambas VMs Linux con páginas personalizadas:
#   - VmImagenes: muestra una galería de imágenes simulada
#   - VmVideo: muestra una galería de videos simulada
# Esto permite verificar el enrutamiento basado en path.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 3: INSTALACIÓN DE NGINX"
echo "═══════════════════════════════════════════════════════════════"

echo "🌐 Instalando Nginx en VmImagenes..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_IMAGENES_NAME" \
  --command-id RunShellScript \
  --scripts '
    # Instalar Nginx
    sudo apt-get update -y
    sudo apt-get install -y nginx

    # Página principal
    sudo tee /var/www/html/index.html > /dev/null <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Servidor de Imagenes</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; max-width: 600px; }
  h1 { font-size: 2.5em; }
  .server { font-size: 1.5em; color: #00ff88; }
  .gallery { display: flex; flex-wrap: wrap; justify-content: center; gap: 10px; margin-top: 20px; }
  .img-placeholder { width: 150px; height: 100px; background: rgba(255,255,255,0.2);
                     border-radius: 8px; display: flex; align-items: center;
                     justify-content: center; font-size: 2em; }
</style></head>
<body>
<div class="container">
  <h1>Servidor de Imagenes</h1>
  <p class="server">VmImagenes - ImagesPool (Linux + Nginx)</p>
  <p>Estud-IA - Laboratorio Application Gateway</p>
  <div class="gallery">
    <div class="img-placeholder">IMG1</div>
    <div class="img-placeholder">IMG2</div>
    <div class="img-placeholder">IMG3</div>
    <div class="img-placeholder">IMG4</div>
    <div class="img-placeholder">IMG5</div>
    <div class="img-placeholder">IMG6</div>
  </div>
</div>
</body></html>
HTMLEOF

    # Crear directorio /imagenes para el path routing
    sudo mkdir -p /var/www/html/imagenes
    sudo tee /var/www/html/imagenes/index.html > /dev/null <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Galeria de Imagenes</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; max-width: 600px; }
  h1 { font-size: 2.5em; }
  .gallery { display: flex; flex-wrap: wrap; justify-content: center; gap: 15px; margin-top: 20px; }
  .img-placeholder { width: 180px; height: 120px; background: rgba(255,255,255,0.2);
                     border-radius: 10px; display: flex; align-items: center;
                     justify-content: center; font-size: 3em; }
</style></head>
<body>
<div class="container">
  <h1>Galeria de Imagenes</h1>
  <p>Ruta: /imagenes/ - ImagesPool - VmImagenes</p>
  <div class="gallery">
    <div class="img-placeholder">IMG1</div>
    <div class="img-placeholder">IMG2</div>
    <div class="img-placeholder">IMG3</div>
    <div class="img-placeholder">IMG4</div>
  </div>
</div>
</body></html>
HTMLEOF

    # Reiniciar Nginx para aplicar cambios
    sudo systemctl restart nginx
    sudo systemctl enable nginx
  ' \
  --output none
echo "  ✅ Nginx instalado en VmImagenes."

echo "🌐 Instalando Nginx en VmVideo..."
az vm run-command invoke \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_VIDEO_NAME" \
  --command-id RunShellScript \
  --scripts '
    # Instalar Nginx
    sudo apt-get update -y
    sudo apt-get install -y nginx

    # Página principal
    sudo tee /var/www/html/index.html > /dev/null <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Servidor de Videos</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; max-width: 600px; }
  h1 { font-size: 2.5em; }
  .server { font-size: 1.5em; color: #00ff88; }
  .gallery { display: flex; flex-wrap: wrap; justify-content: center; gap: 10px; margin-top: 20px; }
  .vid-placeholder { width: 180px; height: 120px; background: rgba(255,255,255,0.2);
                     border-radius: 8px; display: flex; align-items: center;
                     justify-content: center; font-size: 2em; }
</style></head>
<body>
<div class="container">
  <h1>Servidor de Videos</h1>
  <p class="server">VmVideo - VideosPool (Linux + Nginx)</p>
  <p>Estud-IA - Laboratorio Application Gateway</p>
  <div class="gallery">
    <div class="vid-placeholder">VID1</div>
    <div class="vid-placeholder">VID2</div>
    <div class="vid-placeholder">VID3</div>
    <div class="vid-placeholder">VID4</div>
    <div class="vid-placeholder">VID5</div>
    <div class="vid-placeholder">VID6</div>
  </div>
</div>
</body></html>
HTMLEOF

    # Crear directorio /videos para el path routing
    sudo mkdir -p /var/www/html/videos
    sudo tee /var/www/html/videos/index.html > /dev/null <<HTMLEOF
<!DOCTYPE html>
<html>
<head><title>Galeria de Videos</title>
<style>
  body { font-family: Arial, sans-serif; text-align: center; padding: 50px;
         background: linear-gradient(135deg, #f093fb 0%, #f5576c 100%);
         color: white; }
  .container { background: rgba(0,0,0,0.3); padding: 40px; border-radius: 15px;
               display: inline-block; max-width: 600px; }
  h1 { font-size: 2.5em; }
  .gallery { display: flex; flex-wrap: wrap; justify-content: center; gap: 15px; margin-top: 20px; }
  .vid-placeholder { width: 180px; height: 120px; background: rgba(255,255,255,0.2);
                     border-radius: 10px; display: flex; align-items: center;
                     justify-content: center; font-size: 3em; }
</style></head>
<body>
<div class="container">
  <h1>Galeria de Videos</h1>
  <p>Ruta: /videos/ - VideosPool - VmVideo</p>
  <div class="gallery">
    <div class="vid-placeholder">VID1</div>
    <div class="vid-placeholder">VID2</div>
    <div class="vid-placeholder">VID3</div>
    <div class="vid-placeholder">VID4</div>
  </div>
</div>
</body></html>
HTMLEOF

    # Reiniciar Nginx para aplicar cambios
    sudo systemctl restart nginx
    sudo systemctl enable nginx
  ' \
  --output none
echo "  ✅ Nginx instalado en VmVideo."

# =====================================================================
# FASE 4: APPLICATION GATEWAY
# =====================================================================
# Crea el Application Gateway con:
#   1. IP pública estática (Standard SKU)
#   2. Frontend IP Configuration con la IP pública
#   3. Backend Pools: ImagesPool (VmImagenes) y VideosPool (VmVideo)
#   4. HTTP Settings (Settings1): configuración de backend HTTP
#   5. Listener (listener1): escucha en puerto 80
#   6. URL Path Map: enrutamiento basado en ruta
#      - /imagenes/* → ImagesPool
#      - /videos/*   → VideosPool
#      - default     → ImagesPool (ImagenesTarget)
#   7. Routing Rule (RoutingRule1): vincula listener con URL Path Map
#
# IMPORTANTE: La creación del Application Gateway tarda entre
# 15-25 minutos. El comando incluye toda la configuración.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 4: APPLICATION GATEWAY"
echo "═══════════════════════════════════════════════════════════════"

# Obtener las IPs privadas de las VMs para los backend pools
VM_IMAGENES_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_IMAGENES_NAME" \
  --show-details --query "privateIps" -o tsv)
VM_VIDEO_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$VM_VIDEO_NAME" \
  --show-details --query "privateIps" -o tsv)

echo "  📋 IP privada VmImagenes: $VM_IMAGENES_IP"
echo "  📋 IP privada VmVideo:    $VM_VIDEO_IP"

echo "🌍 Creando/verificando IP pública del Application Gateway..."
if exists_public_ip "$APPGW_PUBLIC_IP_NAME"; then
  echo "  ℹ️  IP pública '$APPGW_PUBLIC_IP_NAME' ya existe, se omite creación."
else
  az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APPGW_PUBLIC_IP_NAME" \
    --location "$LOCATION" \
    --sku Standard \
    --allocation-method Static \
    --output none
  echo "  ✅ IP pública creada."
fi

echo "🌐 Creando/verificando Application Gateway..."
echo "   ⏳ Esto puede tardar entre 15-25 minutos..."
if exists_appgw; then
  echo "  ℹ️  Application Gateway '$APPGW_NAME' ya existe, se omite creación."
else
  # ---------------------------------------------------------------
  # Se crea el Application Gateway con la configuración completa:
  #
  # 7.1 Datos básicos: nombre, SKU, tier, capacidad, ubicación
  # 7.2 Frontend: IP pública vinculada al App Gateway
  # 7.3 Backend Pool por defecto: ImagesPool (VmImagenes)
  #
  # El comando 'az network application-gateway create' crea:
  #   - El gateway con su frontend
  #   - Un backend pool por defecto
  #   - HTTP settings por defecto
  #   - Un listener por defecto
  #   - Una regla básica por defecto
  # ---------------------------------------------------------------
  az network application-gateway create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$APPGW_NAME" \
    --location "$LOCATION" \
    --sku "$APPGW_SKU" \
    --capacity 2 \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_APPGW_NAME" \
    --public-ip-address "$APPGW_PUBLIC_IP_NAME" \
    --frontend-port 80 \
    --http-settings-port 80 \
    --http-settings-protocol HTTP \
    --priority 1 \
    --servers "$VM_IMAGENES_IP" \
    --output none
  echo "  ✅ Application Gateway creado."
fi

# ----- 7.3 Agregar Backend Pool: ImagesPool -----
# Backend pool que contiene la IP de VmImagenes.
echo "📦 Configurando Backend Pool: ImagesPool..."
EXISTING_IMAGES_POOL=$(az network application-gateway address-pool show \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  -n "$BACKEND_POOL_IMAGES" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_IMAGES_POOL" ]]; then
  echo "  ℹ️  Backend Pool '$BACKEND_POOL_IMAGES' ya existe."
else
  az network application-gateway address-pool create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$BACKEND_POOL_IMAGES" \
    --servers "$VM_IMAGENES_IP" \
    --output none
  echo "  ✅ Backend Pool '$BACKEND_POOL_IMAGES' creado con IP: $VM_IMAGENES_IP"
fi

# ----- 7.4 Agregar Backend Pool: VideosPool -----
# Backend pool que contiene la IP de VmVideo.
echo "📦 Configurando Backend Pool: VideosPool..."
EXISTING_VIDEOS_POOL=$(az network application-gateway address-pool show \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  -n "$BACKEND_POOL_VIDEOS" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_VIDEOS_POOL" ]]; then
  echo "  ℹ️  Backend Pool '$BACKEND_POOL_VIDEOS' ya existe."
else
  az network application-gateway address-pool create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$BACKEND_POOL_VIDEOS" \
    --servers "$VM_VIDEO_IP" \
    --output none
  echo "  ✅ Backend Pool '$BACKEND_POOL_VIDEOS' creado con IP: $VM_VIDEO_IP"
fi

# ----- 8.8.1 Configuración de Backend: Settings1 -----
# Define cómo el App Gateway se comunica con los backends:
#   - Protocolo: HTTP
#   - Puerto: 80
#   - Timeout: 30 segundos
#   - Afinidad de cookie: deshabilitada (distribución equitativa)
echo "⚙️  Configurando HTTP Settings: $BACKEND_SETTINGS_NAME..."
EXISTING_SETTINGS=$(az network application-gateway http-settings show \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  -n "$BACKEND_SETTINGS_NAME" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_SETTINGS" ]]; then
  echo "  ℹ️  HTTP Settings '$BACKEND_SETTINGS_NAME' ya existe."
else
  az network application-gateway http-settings create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$BACKEND_SETTINGS_NAME" \
    --port 80 \
    --protocol HTTP \
    --timeout 30 \
    --output none
  echo "  ✅ HTTP Settings '$BACKEND_SETTINGS_NAME' creado."
fi

# =====================================================================
# FASE 5: REGLAS DE ENRUTAMIENTO (URL Path-Based Routing)
# =====================================================================
# Configura el enrutamiento basado en rutas URL:
#
# 8.1 Nombre de la regla: RoutingRule1
# 8.2 Prioridad: 1
# 8.3 Listener: listener1 (escucha HTTP:80)
# 8.4 IP pública del Application Gateway
# 8.5 Puerto 80
# 8.6-8.7 Destinos:
#   - /imagenes/* → ImagesPool (ImagenesTarget)
#   - /videos/*   → VideosPool
#   - Default     → ImagesPool
# 8.8.1 Configuración de backend: Settings1
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  FASE 5: REGLAS DE ENRUTAMIENTO"
echo "═══════════════════════════════════════════════════════════════"

# ----- URL Path Map -----
# Define las reglas de enrutamiento basadas en la URL:
#   /imagenes/* → ImagesPool (con Settings1)
#   /videos/*   → VideosPool (con Settings1)
#   Default     → ImagesPool (ImagenesTarget)
echo "🗺️  Creando/verificando URL Path Map..."
EXISTING_PATH_MAP=$(az network application-gateway url-path-map show \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  -n "$URL_PATH_MAP_NAME" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_PATH_MAP" ]]; then
  echo "  ℹ️  URL Path Map '$URL_PATH_MAP_NAME' ya existe."
else
  # Crear el URL Path Map con la primera regla (imágenes)
  # El default-address-pool es ImagesPool (ImagenesTarget = destino por defecto)
  az network application-gateway url-path-map create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$URL_PATH_MAP_NAME" \
    --paths "/imagenes/*" \
    --address-pool "$BACKEND_POOL_IMAGES" \
    --http-settings "$BACKEND_SETTINGS_NAME" \
    --default-address-pool "$BACKEND_POOL_IMAGES" \
    --default-http-settings "$BACKEND_SETTINGS_NAME" \
    --rule-name "ImagenesTarget" \
    --output none
  echo "  ✅ URL Path Map creado: /imagenes/* → ImagesPool (default: ImagesPool)"
fi

# Agregar regla de path para /videos/*
echo "🗺️  Agregando regla de path: /videos/* → VideosPool..."
EXISTING_VIDEO_RULE=$(az network application-gateway url-path-map rule show \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  --path-map-name "$URL_PATH_MAP_NAME" \
  -n "VideosTarget" --query "name" -o tsv 2>/dev/null || true)

if [[ -n "$EXISTING_VIDEO_RULE" ]]; then
  echo "  ℹ️  Regla 'VideosTarget' ya existe en el URL Path Map."
else
  az network application-gateway url-path-map rule create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --path-map-name "$URL_PATH_MAP_NAME" \
    --name "VideosTarget" \
    --paths "/videos/*" \
    --address-pool "$BACKEND_POOL_VIDEOS" \
    --http-settings "$BACKEND_SETTINGS_NAME" \
    --output none
  echo "  ✅ Regla agregada: /videos/* → VideosPool"
fi

# ----- Actualizar la regla de routing para usar URL Path Map -----
# Se actualiza la regla por defecto (creada con el App Gateway)
# para que use el URL Path Map en lugar de un backend fijo.
# Esto convierte la regla de "Basic" a "Path-based".
echo "📐 Configurando regla de enrutamiento con URL Path Map..."

# Obtener el nombre de la regla existente (creada automáticamente)
DEFAULT_RULE_NAME=$(az network application-gateway rule list \
  -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
  --query "[0].name" -o tsv 2>/dev/null || true)

if [[ -n "$DEFAULT_RULE_NAME" ]]; then
  # Actualizar la regla existente para usar el URL Path Map
  az network application-gateway rule update \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$DEFAULT_RULE_NAME" \
    --rule-type PathBasedRouting \
    --url-path-map "$URL_PATH_MAP_NAME" \
    --priority 1 \
    --output none 2>/dev/null || true
  echo "  ✅ Regla '$DEFAULT_RULE_NAME' actualizada con URL Path Map (prioridad 1)."
else
  echo "  ⚠️  No se encontró regla por defecto. Creando nueva..."
  # Obtener el nombre del listener por defecto
  DEFAULT_LISTENER=$(az network application-gateway http-listener list \
    -g "$RESOURCE_GROUP" --gateway-name "$APPGW_NAME" \
    --query "[0].name" -o tsv)

  az network application-gateway rule create \
    --resource-group "$RESOURCE_GROUP" \
    --gateway-name "$APPGW_NAME" \
    --name "$ROUTING_RULE_NAME" \
    --rule-type PathBasedRouting \
    --http-listener "$DEFAULT_LISTENER" \
    --url-path-map "$URL_PATH_MAP_NAME" \
    --address-pool "$BACKEND_POOL_IMAGES" \
    --http-settings "$BACKEND_SETTINGS_NAME" \
    --priority 1 \
    --output none
  echo "  ✅ Regla '$ROUTING_RULE_NAME' creada con URL Path Map (prioridad 1)."
fi

# =====================================================================
# VERIFICACIÓN FINAL
# =====================================================================
# Muestra las IPs de acceso y la configuración del Application Gateway.
# =====================================================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  VERIFICACIÓN FINAL"
echo "═══════════════════════════════════════════════════════════════"

# Obtener la IP pública del Application Gateway
APPGW_PUBLIC_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$APPGW_PUBLIC_IP_NAME" \
  --query "ipAddress" \
  --output tsv)

echo ""
echo "✅ Despliegue finalizado exitosamente"
echo ""
echo "📋 Recursos creados:"
echo "   ├── Resource Group:        $RESOURCE_GROUP"
echo "   ├── VNet:                  $VNET_NAME"
echo "   ├── Subred App Gateway:    $SUBNET_APPGW_NAME ($SUBNET_APPGW_PREFIX)"
echo "   ├── Subred Backend:        $SUBNET_BACKEND_NAME ($SUBNET_BACKEND_PREFIX)"
echo "   ├── NSG:                   $NSG_NAME"
echo "   ├── Application Gateway:   $APPGW_NAME ($APPGW_SKU)"
echo "   ├── Backend Pool Imágenes: $BACKEND_POOL_IMAGES → $VM_IMAGENES_IP"
echo "   ├── Backend Pool Videos:   $BACKEND_POOL_VIDEOS → $VM_VIDEO_IP"
echo "   ├── VM Imágenes:           $VM_IMAGENES_NAME (Ubuntu 22.04 + Nginx)"
echo "   └── VM Video:              $VM_VIDEO_NAME (Ubuntu 22.04 + Nginx)"
echo ""
echo "🌐 Acceso:"
echo "   ├── Página principal: http://$APPGW_PUBLIC_IP"
echo "   ├── Imágenes:         http://$APPGW_PUBLIC_IP/imagenes/"
echo "   └── Videos:           http://$APPGW_PUBLIC_IP/videos/"
echo ""
echo "🗺️  Reglas de enrutamiento:"
echo "   ├── /imagenes/* → ImagesPool ($VM_IMAGENES_NAME)"
echo "   ├── /videos/*   → VideosPool ($VM_VIDEO_NAME)"
echo "   └── /* (default) → ImagesPool ($VM_IMAGENES_NAME)"
echo ""
echo "🔎 Verificación rápida:"
echo "   curl http://$APPGW_PUBLIC_IP"
echo "   curl http://$APPGW_PUBLIC_IP/imagenes/"
echo "   curl http://$APPGW_PUBLIC_IP/videos/"
echo ""
echo "📝 Log completo en: $LOG_FILE"
