# 🌐 Application Gateway con Enrutamiento por URL

Script de despliegue automatizado de un **Azure Application Gateway (Standard V2)** con enrutamiento basado en rutas URL hacia dos servidores backend.

---

## 📋 Índice

- [Descripción](#-descripción)
- [Arquitectura](#-arquitectura)
- [Prerequisitos](#-prerequisitos)
- [Uso](#-uso)
- [Recursos creados](#-recursos-creados)
- [Reglas de enrutamiento](#-reglas-de-enrutamiento)
- [Verificación](#-verificación)
- [Parámetros configurables](#-parámetros-configurables)

---

## 📝 Descripción

`app_gateway.sh` es un script Bash **idempotente y no destructivo** que despliega:

- Red virtual con dos subredes (App Gateway + Backend)
- Network Security Group (NSG) con reglas HTTP, RDP y health probes
- Dos VMs Windows Server 2022 sin IP pública, con IIS:
  - **VmImagenes**: sirve contenido de imágenes
  - **VmVideo**: sirve contenido de videos
- Application Gateway (Standard V2) con IP pública
- Dos Backend Pools (ImagesPool, VideosPool)
- URL Path Map para enrutamiento basado en ruta
- Regla de enrutamiento con prioridad 1

---

## 🏗️ Arquitectura

```
Internet
   │
   ▼
┌──────────────────────────────────┐
│   Application Gateway            │
│   (Standard V2, IP pública)      │
│   Listener: HTTP:80              │
├──────────────────────────────────┤
│  URL Path Map:                   │
│  ├── /imagenes/* → ImagesPool    │
│  ├── /videos/*   → VideosPool    │
│  └── /* default  → ImagesPool    │
└──────────┬───────────┬───────────┘
           │           │
     ImagesPool   VideosPool
           │           │
     ┌─────┘           └─────┐
     ▼                       ▼
┌──────────┐          ┌──────────┐
│VmImagenes│          │ VmVideo  │
│   IIS    │          │   IIS    │
│ 🖼️ Imgs  │          │ 🎬 Vids  │
│ 10.0.4.x │          │ 10.0.4.x │
└──────────┘          └──────────┘
     SubNetBackendPool (10.0.4.0/24)
```

---

## ✅ Prerequisitos

- Azure CLI instalado y autenticado (`az login`)
- Suscripción Azure activa con permisos de **Contributor**
- Ejecutar en **Azure Cloud Shell (Bash)** o terminal con `az` CLI

---

## 🚀 Uso

```bash
chmod +x app_gateway.sh
bash app_gateway.sh
```

> ⚠️ **NO** ejecutar con `source` (si hay error, cierra la sesión).

El script tarda aproximadamente **20-30 minutos** (el Application Gateway es el recurso que más tarda).

---

## 📦 Recursos creados

| Recurso | Nombre | Descripción |
|---|---|---|
| Resource Group | `GrupoNube` | Contenedor de todos los recursos |
| VNet | `NubeVnet` | Red virtual 10.0.0.0/16 |
| Subred App Gateway | `SubnetAppGateway` | 10.0.3.0/24 (exclusiva del gateway) |
| Subred Backend | `SubNetBackendPool` | 10.0.4.0/24 (VMs backend) |
| NSG | `appgw-backend-nsg` | Reglas HTTP, RDP y health probes |
| Application Gateway | `NubeAppGateway` | Standard V2, capacidad 2 |
| Backend Pool | `ImagesPool` | VmImagenes |
| Backend Pool | `VideosPool` | VmVideo |
| HTTP Settings | `Settings1` | HTTP:80, timeout 30s |
| VM Imágenes | `VmImagenes` | Windows Server 2022 + IIS (galería imágenes) |
| VM Video | `VmVideo` | Windows Server 2022 + IIS (galería videos) |

---

## 🗺️ Reglas de enrutamiento

| Ruta | Backend Pool | VM Destino | Contenido |
|---|---|---|---|
| `/imagenes/*` | ImagesPool | VmImagenes | Galería de imágenes |
| `/videos/*` | VideosPool | VmVideo | Galería de videos |
| `/*` (default) | ImagesPool | VmImagenes | Página por defecto |

**Configuración de la regla:**
- **Nombre:** RoutingRule1
- **Prioridad:** 1
- **Listener:** listener1 (HTTP:80, IP pública)
- **Tipo:** Path-based Routing
- **Backend Settings:** Settings1

---

## 🔎 Verificación

Una vez completado el despliegue:

```bash
# Página por defecto (ImagesPool)
curl http://<APPGW_PUBLIC_IP>

# Galería de imágenes
curl http://<APPGW_PUBLIC_IP>/imagenes/

# Galería de videos
curl http://<APPGW_PUBLIC_IP>/videos/
```

Cada URL mostrará una página diferente, confirmando que el enrutamiento por path funciona correctamente.

---

## ⚙️ Parámetros configurables

| Variable | Valor por defecto | Descripción |
|---|---|---|
| `RESOURCE_GROUP` | `GrupoNube` | Nombre del Resource Group |
| `LOCATION` | `eastus2` | Región de Azure |
| `VNET_NAME` | `NubeVnet` | Nombre de la VNet |
| `SUBNET_APPGW_PREFIX` | `10.0.3.0/24` | CIDR subred App Gateway |
| `SUBNET_BACKEND_PREFIX` | `10.0.4.0/24` | CIDR subred Backend |
| `VM_SIZE` | `Standard_D2s_v3` | Tamaño de las VMs |
| `WINDOWS_IMAGE` | `Win2022Datacenter` | Imagen del SO |
| `ADMIN_USER` | `azureuser` | Usuario administrador |
| `ADMIN_PASSWORD` | `Admin123456.` | Contraseña de administrador |
| `APPGW_SKU` | `Standard_v2` | SKU del Application Gateway |
