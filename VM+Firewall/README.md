# 🚀 Deploy Azure Completo

Script de despliegue automatizado de infraestructura Azure con **Azure Firewall**, **DNAT**, **UDR** y **Firewall Policy**.

---

## 📋 Índice

- [Descripción](#-descripción)
- [Arquitectura](#-arquitectura)
- [Prerequisitos](#-prerequisitos)
- [Uso](#-uso)
- [Recursos creados](#-recursos-creados)
- [Flujo de ejecución](#-flujo-de-ejecución)
- [Topología de red](#-topología-de-red)
- [Firewall Policy — estructura de reglas](#-firewall-policy--estructura-de-reglas)
- [Flujo de tráfico DNAT](#-flujo-de-tráfico-dnat)
- [Flujo de tráfico saliente (UDR)](#-flujo-de-tráfico-saliente-udr)
- [Lógica de idempotencia](#-lógica-de-idempotencia)
- [Manejo de consistencia eventual](#-manejo-de-consistencia-eventual)
- [Parámetros configurables](#-parámetros-configurables)
- [Acceso a las VMs](#-acceso-a-las-vms)
- [Verificación](#-verificación)
- [Troubleshooting](#-troubleshooting)
- [Notas de seguridad](#-notas-de-seguridad)

---

## 📝 Descripción

`deploy-azure-completo.sh` es un script Bash **idempotente y no destructivo** que despliega una infraestructura completa en Azure:

- Red virtual con dos subredes (workload + firewall)
- Dos máquinas virtuales sin IP pública (Linux + Windows)
- Azure Firewall con IP pública estática
- Enrutamiento forzado (UDR) de toda la subred a través del Firewall
- Firewall Policy con reglas DNAT y Network

El script puede ejecutarse múltiples veces sin duplicar recursos ni borrar reglas existentes.

---

## 🏗️ Arquitectura

```mermaid
graph TB
    subgraph Internet
        USER[👤 Usuario Remoto]
    end

    subgraph Azure["☁️ Azure - GrupNube (eastus2)"]
        subgraph VNet["NubeVnet (10.0.0.0/16)"]
            subgraph FWSubnet["AzureFirewallSubnet<br/>10.0.0.0/26"]
                FW[🔥 NubeFirewall<br/>IP Privada: 10.0.0.4]
            end

            subgraph WorkSubnet["SubNetHome<br/>10.0.1.0/24"]
                LINUX[🐧 vps-linux-01<br/>Ubuntu 22.04<br/>Sin IP Pública]
                WIN[🪟 vps-windows-01<br/>Windows Server 2022<br/>Sin IP Pública]
            end
        end

        PUBIP[🌐 NubeFirewallPublicIP<br/>IP Estática Standard]
        POLICY[📜 NubeFirewallPolicy]
        UDR[🧭 rt-workload-to-firewall<br/>0.0.0.0/0 → Firewall]
    end

    USER -->|":3389 RDP"| PUBIP
    USER -->|":2201 SSH"| PUBIP
    PUBIP --> FW
    FW -->|"DNAT :3389→:3389"| WIN
    FW -->|"DNAT :2201→:22"| LINUX
    POLICY -.->|"asociada"| FW
    UDR -.->|"asociada"| WorkSubnet
    WorkSubnet -->|"todo tráfico"| FW

    style FW fill:#ff6b35,stroke:#333,color:#fff
    style PUBIP fill:#0078d4,stroke:#333,color:#fff
    style LINUX fill:#e95420,stroke:#333,color:#fff
    style WIN fill:#0078d4,stroke:#333,color:#fff
    style POLICY fill:#50c878,stroke:#333,color:#fff
    style UDR fill:#ffd700,stroke:#333,color:#000
```

---

## ✅ Prerequisitos

| Requisito | Detalle |
|-----------|---------|
| **Azure CLI** | Instalado y autenticado (`az login`) |
| **Suscripción** | Azure activa con permisos de **Contributor** |
| **Entorno** | Azure Cloud Shell (Bash) o terminal con `az` CLI |
| **Bash** | Versión 4+ (Cloud Shell lo cumple) |

---

## 🚀 Uso

### Desde Azure Cloud Shell

1. Abrir [https://shell.azure.com](https://shell.azure.com) (modo **Bash**)
2. Subir el archivo con el botón **Upload** (📤)
3. Ejecutar:

```bash
chmod +x deploy-azure-completo.sh
bash deploy-azure-completo.sh
```

> ⚠️ **NUNCA usar `source`**: si hay un error, `set -e` + `exit` cerrarán tu sesión de Cloud Shell.

### Log de ejecución

El log completo se guarda en `~/deploy-azure-completo.log`:

```bash
cat ~/deploy-azure-completo.log
```

---

## 📦 Recursos creados

| # | Recurso | Nombre | Tipo |
|---|---------|--------|------|
| 1 | Resource Group | `GrupNube` | Contenedor lógico |
| 2 | Virtual Network | `NubeVnet` (10.0.0.0/16) | Red virtual |
| 3 | Subred Workload | `SubNetHome` (10.0.1.0/24) | Subred para VMs |
| 4 | Subred Firewall | `AzureFirewallSubnet` (10.0.0.0/26) | Subred exclusiva FW |
| 5 | VM Linux | `vps-linux-01` (Ubuntu 22.04) | Standard_D2s_v3 |
| 6 | VM Windows | `vps-windows-01` (Win Server 2022) | Standard_D2s_v3 |
| 7 | IP Pública | `NubeFirewallPublicIP` | Standard, Estática |
| 8 | Azure Firewall | `NubeFirewall` | Standard, AZFW_VNet |
| 9 | Route Table | `rt-workload-to-firewall` | UDR |
| 10 | Ruta | `default-to-firewall` | 0.0.0.0/0 → FW |
| 11 | Firewall Policy | `NubeFirewallPolicy` | Standard |
| 12 | Rule Collection Group | `Default-Connection-Policies` | Prioridad 100 |
| 13 | NAT Collection | `DNAT-Inbound` | Prioridad 100 |
| 14 | Network Collection | `Allow-Admin-Web` | Prioridad 200 |

### Reglas creadas

| Regla | Tipo | Origen | Destino | Puerto | Acción |
|-------|------|--------|---------|--------|--------|
| DNAT-Win-RDP | DNAT | `*` | Firewall IP `:3389` | → Windows `:3389` | Redirect |
| DNAT-Linux-SSH | DNAT | `*` | Firewall IP `:2201` | → Linux `:22` | Redirect |
| Allow-RDP | Network | `*` | `10.0.1.0/24` `:3389` | TCP | Allow |
| Allow-HTTP | Network | `*` | `10.0.1.0/24` `:80` | TCP | Allow |
| Allow-HTTPS | Network | `*` | `10.0.1.0/24` `:443` | TCP | Allow |
| Allow-SSH | Network | `*` | `10.0.1.0/24` `:22` | TCP | Allow |

---

## 🔄 Flujo de ejecución

```mermaid
flowchart TD
    START([🚀 Inicio]) --> INIT[Configurar log + verificar az CLI]

    INIT --> PHASE1

    subgraph PHASE1["FASE 1: Red + VMs"]
        RG{Resource Group<br/>¿existe?}
        RG -->|No| RG_CREATE[Crear Resource Group]
        RG -->|Sí| RG_SKIP[Omitir]
        RG_CREATE --> VNET
        RG_SKIP --> VNET

        VNET{VNet<br/>¿existe?}
        VNET -->|No| VNET_CREATE[Crear VNet + SubNetHome]
        VNET -->|Sí| VNET_SKIP[Omitir]
        VNET_CREATE --> FWSUB
        VNET_SKIP --> FWSUB

        FWSUB{AzureFirewallSubnet<br/>¿existe?}
        FWSUB -->|No| FWSUB_CREATE[Crear subred firewall]
        FWSUB -->|Sí| FWSUB_SKIP[Omitir]
        FWSUB_CREATE --> VMS
        FWSUB_SKIP --> VMS

        VMS[Crear VMs si no existen<br/>+ Abrir puertos NSG]
    end

    PHASE1 --> PHASE2

    subgraph PHASE2["FASE 2: Firewall + UDR"]
        PUBIP{IP Pública<br/>¿existe?}
        PUBIP -->|No| PUBIP_CREATE[Crear IP Pública Standard]
        PUBIP -->|Sí| PUBIP_SKIP[Omitir]
        PUBIP_CREATE --> FWALL
        PUBIP_SKIP --> FWALL

        FWALL{Firewall<br/>¿existe?}
        FWALL -->|No| FWALL_CREATE[Crear Azure Firewall]
        FWALL -->|Sí| FWALL_SKIP[Omitir]
        FWALL_CREATE --> IPCONF
        FWALL_SKIP --> IPCONF

        IPCONF[Vincular Firewall a VNet]
        IPCONF --> UDR_RT[Crear Route Table + Ruta default]
        UDR_RT --> UDR_ASSOC[Asociar UDR a SubNetHome]
    end

    PHASE2 --> PHASE3

    subgraph PHASE3["FASE 3: Firewall Policy"]
        POL{Policy<br/>¿existe?}
        POL -->|No| POL_CREATE[Crear Firewall Policy]
        POL -->|Sí| POL_SKIP[Omitir]
        POL_CREATE --> CLEAN
        POL_SKIP --> CLEAN

        CLEAN{¿Firewall tiene<br/>Policy asociada?}
        CLEAN -->|No| CLASSIC[Borrar reglas clásicas<br/>+ Asociar Policy<br/>+ Esperar propagación]
        CLEAN -->|Sí| CLEAN_SKIP[Omitir]
        CLASSIC --> RCG
        CLEAN_SKIP --> RCG

        RCG{RCG<br/>¿existe?}
        RCG -->|No| RCG_CREATE[Crear Rule Collection Group]
        RCG -->|Sí| RCG_SKIP[Omitir]
        RCG_CREATE --> RULES
        RCG_SKIP --> RULES

        RULES[Crear collections + reglas<br/>solo si no existen]
    end

    PHASE3 --> VERIFY[🔎 Verificación de reglas]
    VERIFY --> DONE([✅ Despliegue finalizado])

    style PHASE1 fill:#e8f5e9,stroke:#4caf50
    style PHASE2 fill:#fff3e0,stroke:#ff9800
    style PHASE3 fill:#e3f2fd,stroke:#2196f3
    style DONE fill:#c8e6c9,stroke:#2e7d32
```

---

## 🌐 Topología de red

```mermaid
graph LR
    subgraph Internet
        CLI[👤 Cliente<br/>tu PC]
    end

    subgraph AzureFirewallSubnet["AzureFirewallSubnet<br/>10.0.0.0/26"]
        FW["🔥 NubeFirewall<br/>Privada: 10.0.0.4<br/>Pública: x.x.x.x"]
    end

    subgraph SubNetHome["SubNetHome<br/>10.0.1.0/24"]
        direction TB
        VM1["🐧 vps-linux-01<br/>10.0.1.5"]
        VM2["🪟 vps-windows-01<br/>10.0.1.4"]
    end

    CLI -- ":3389 TCP" --> FW
    CLI -- ":2201 TCP" --> FW
    FW -- "DNAT → :3389" --> VM2
    FW -- "DNAT → :22" --> VM1

    VM1 -- "UDR 0.0.0.0/0" --> FW
    VM2 -- "UDR 0.0.0.0/0" --> FW

    style FW fill:#ff6b35,stroke:#333,color:#fff
    style VM1 fill:#e95420,stroke:#333,color:#fff
    style VM2 fill:#0078d4,stroke:#333,color:#fff
```

---

## 📜 Firewall Policy — estructura de reglas

```mermaid
graph TD
    POLICY["📜 NubeFirewallPolicy<br/>(Standard SKU)"]

    POLICY --> RCG["📁 Default-Connection-Policies<br/>Rule Collection Group<br/>Prioridad: 100"]

    RCG --> NAT["🔀 DNAT-Inbound<br/>NAT Collection<br/>Prioridad: 100<br/>Acción: DNAT"]
    RCG --> NET["🛡️ Allow-Admin-Web<br/>Network Collection<br/>Prioridad: 200<br/>Acción: Allow"]

    NAT --> R1["DNAT-Win-RDP<br/>*:3389 → Windows:3389"]
    NAT --> R2["DNAT-Linux-SSH<br/>*:2201 → Linux:22"]

    NET --> R3["Allow-RDP<br/>* → 10.0.1.0/24:3389"]
    NET --> R4["Allow-HTTP<br/>* → 10.0.1.0/24:80"]
    NET --> R5["Allow-HTTPS<br/>* → 10.0.1.0/24:443"]
    NET --> R6["Allow-SSH<br/>* → 10.0.1.0/24:22"]

    style POLICY fill:#50c878,stroke:#333,color:#fff
    style RCG fill:#4a90d9,stroke:#333,color:#fff
    style NAT fill:#ff6b35,stroke:#333,color:#fff
    style NET fill:#9b59b6,stroke:#333,color:#fff
    style R1 fill:#ffe0b2,stroke:#e65100
    style R2 fill:#ffe0b2,stroke:#e65100
    style R3 fill:#e1bee7,stroke:#6a1b9a
    style R4 fill:#e1bee7,stroke:#6a1b9a
    style R5 fill:#e1bee7,stroke:#6a1b9a
    style R6 fill:#e1bee7,stroke:#6a1b9a
```

---

## 🔀 Flujo de tráfico DNAT

Cómo llega el tráfico RDP/SSH desde Internet hasta las VMs:

```mermaid
sequenceDiagram
    actor User as 👤 Usuario
    participant PubIP as 🌐 Firewall Public IP
    participant FW as 🔥 Azure Firewall
    participant NSG as 🛡️ NSG VM
    participant VM as 💻 VM Destino

    Note over User,VM: Conexión RDP (puerto 3389)
    User->>PubIP: TCP SYN → x.x.x.x:3389
    PubIP->>FW: Paquete llega al Firewall
    FW->>FW: Evalúa DNAT-Inbound rules
    FW->>FW: Match: DNAT-Win-RDP<br/>Reescribe destino → 10.0.1.4:3389
    FW->>NSG: Paquete → 10.0.1.4:3389
    NSG->>NSG: Evalúa regla: Allow port 3389 ✅
    NSG->>VM: Paquete llega a Windows VM
    VM-->>User: Respuesta RDP

    Note over User,VM: Conexión SSH (puerto 2201)
    User->>PubIP: TCP SYN → x.x.x.x:2201
    PubIP->>FW: Paquete llega al Firewall
    FW->>FW: Evalúa DNAT-Inbound rules
    FW->>FW: Match: DNAT-Linux-SSH<br/>Reescribe destino → 10.0.1.5:22
    FW->>NSG: Paquete → 10.0.1.5:22
    NSG->>NSG: Evalúa regla: Allow port 22 ✅
    NSG->>VM: Paquete llega a Linux VM
    VM-->>User: Respuesta SSH
```

---

## 📤 Flujo de tráfico saliente (UDR)

Cómo sale el tráfico de las VMs hacia Internet a través del Firewall:

```mermaid
sequenceDiagram
    participant VM as 💻 VM (10.0.1.x)
    participant UDR as 🧭 UDR
    participant FW as 🔥 Azure Firewall
    participant NET as 🌐 Internet

    VM->>UDR: Tráfico saliente → 0.0.0.0/0
    UDR->>UDR: Ruta: 0.0.0.0/0 → VirtualAppliance<br/>Next hop: 10.0.0.4 (Firewall)
    UDR->>FW: Redirige todo el tráfico al Firewall
    FW->>FW: Evalúa Network Rules<br/>(Allow-Admin-Web collection)
    alt Tráfico permitido
        FW->>NET: SNAT → sale con IP Pública del Firewall
        NET-->>FW: Respuesta
        FW-->>VM: Respuesta de vuelta a la VM
    else Tráfico denegado
        FW->>FW: Drop ❌ (deny by default)
    end
```

---

## 🔒 Lógica de idempotencia

El script verifica cada recurso antes de crearlo:

```mermaid
flowchart TD
    CHECK{¿Recurso existe?<br/>exists_*}
    CHECK -->|Sí| SKIP["ℹ️ Ya existe, se omite"]
    CHECK -->|No| CREATE["➕ Crear recurso"]
    CREATE --> WAIT{¿Necesita propagación?}
    WAIT -->|Sí| POLL["⏳ wait_for_*<br/>Polling cada 10-15s"]
    WAIT -->|No| NEXT[Siguiente recurso]
    POLL --> TIMEOUT{¿Timeout?}
    TIMEOUT -->|No| READY["✅ Recurso disponible"]
    TIMEOUT -->|Sí| FAIL["❌ Error: timeout"]
    READY --> NEXT
    SKIP --> NEXT

    style CHECK fill:#fff9c4,stroke:#f57f17
    style SKIP fill:#e8f5e9,stroke:#4caf50
    style CREATE fill:#e3f2fd,stroke:#2196f3
    style POLL fill:#fff3e0,stroke:#ff9800
    style FAIL fill:#ffcdd2,stroke:#c62828
```

### Funciones de existencia

| Función | Verifica |
|---------|----------|
| `exists_resource_group` | Resource Group |
| `exists_vnet` | Virtual Network |
| `exists_subnet` | Subred dentro de VNet |
| `exists_vm` | Máquina Virtual |
| `exists_public_ip` | IP Pública |
| `exists_firewall` | Azure Firewall |
| `exists_firewall_ip_config` | IP Config del Firewall |
| `exists_route_table` | Tabla de rutas (UDR) |
| `exists_route` | Ruta dentro de tabla |
| `exists_firewall_policy` | Firewall Policy |
| `firewall_has_policy` | Si el FW tiene Policy asociada |
| `exists_policy_rcg` | Rule Collection Group |
| `exists_policy_collection` | Collection (NAT/Network) |
| `exists_policy_rule` | Regla individual |

---

## ⏳ Manejo de consistencia eventual

Azure no garantiza disponibilidad inmediata después de crear un recurso. El script usa funciones de polling:

```mermaid
flowchart LR
    CREATE["az ... create"] --> SLEEP["sleep 10<br/>(buffer extra)"]
    SLEEP --> POLL["wait_for_*()"]
    POLL --> QUERY["az ... show<br/>(consultar API)"]
    QUERY --> EXISTS{¿Existe?}
    EXISTS -->|No| WAIT["sleep 10-15s"]
    WAIT --> ELAPSED{¿Timeout?}
    ELAPSED -->|No| QUERY
    ELAPSED -->|Sí| ERROR["❌ Abort"]
    EXISTS -->|Sí| OK["✅ Continuar"]
```

| Función | Recurso esperado | Timeout | Intervalo |
|---------|-----------------|---------|-----------|
| `wait_for_firewall_policy_association` | Policy vinculada al FW | 30 min | 15s |
| `wait_for_policy_rcg` | Rule Collection Group | 15 min | 10s |
| `wait_for_policy_collection` | NAT/Network Collection | 15 min | 10s |

---

## ⚙️ Parámetros configurables

Edita las variables al inicio del script para personalizar el despliegue:

| Variable | Valor por defecto | Descripción |
|----------|-------------------|-------------|
| `RESOURCE_GROUP` | `GrupNube` | Nombre del Resource Group |
| `LOCATION` | `eastus2` | Región Azure |
| `VNET_PREFIX` | `10.0.0.0/16` | Espacio de direcciones de la VNet |
| `SUBNET_WORKLOAD_PREFIX` | `10.0.1.0/24` | Subred de las VMs |
| `VM_SIZE` | `Standard_D2s_v3` | Tamaño de las VMs (2 vCPU, 8 GB) |
| `ADMIN_USER` | `azureuser` | Usuario administrador |
| `WINDOWS_PASSWORD` | `Admin123456.` | Contraseña Windows |
| `CREATE_VM_WITHOUT_PUBLIC_IP` | `true` | `true` = sin IP pública |
| `RDP_EXTERNAL_PORT` | `3389` | Puerto externo para RDP |
| `SSH_EXTERNAL_PORT` | `2201` | Puerto externo para SSH |

---

## 🔌 Acceso a las VMs

Tras ejecutar el script, accede a las VMs a través de la IP pública del Firewall:

### RDP a Windows

```
mstsc /v:<FIREWALL_PUBLIC_IP>:3389
```

- Usuario: `azureuser`
- Contraseña: `Admin123456.`

### SSH a Linux

```bash
ssh -p 2201 azureuser@<FIREWALL_PUBLIC_IP>
```

> La IP pública del Firewall se muestra al finalizar el script.

---

## 🔎 Verificación

Al finalizar, el script imprime un resumen:

```
✅ Despliegue finalizado
🌐 Firewall Public IP: 20.57.47.172
🪟 RDP Windows: 20.57.47.172:3389
🐧 SSH Linux:   20.57.47.172:2201

🔎 Verificación de reglas en Firewall Policy:
   DNAT-Win-RDP:   OK
   DNAT-Linux-SSH: OK
   Allow-RDP:      OK
   Allow-HTTP:     OK
   Allow-HTTPS:    OK
   Allow-SSH:      OK
```

### Verificación manual con Azure CLI

```bash
# Ver reglas en la Policy
az network firewall policy rule-collection-group show \
  -g GrupNube --policy-name NubeFirewallPolicy \
  -n Default-Connection-Policies \
  --query "ruleCollections[].{name:name, rules:rules[].name}" \
  -o table

# Ver IP pública del Firewall
az network public-ip show -g GrupNube -n NubeFirewallPublicIP --query ipAddress -o tsv

# Ver UDR asociada a la subred
az network vnet subnet show -g GrupNube --vnet-name NubeVnet -n SubNetHome --query routeTable.id -o tsv
```

---

## 🔧 Troubleshooting

| Error | Causa | Solución |
|-------|-------|----------|
| `AzureFirewallPolicyAndRuleCollectionsConflict` | Existen reglas clásicas + Policy | El script las limpia automáticamente |
| `The request is invalid` | Consistencia eventual (collection no propagada) | El script espera con `wait_for_*` + `sleep 10` |
| `LinkedInvalidPropertyId` | Se pasó nombre en vez de ID de resource | El script usa ID completo via `az ... show --query id` |
| Terminal se cierra al ejecutar | Se usó `source` en vez de `bash` | Usar: `bash deploy-azure-completo.sh` |
| No conecta RDP | NSG no tiene puerto 3389 abierto | El script abre puertos NSG automáticamente |
| Timeout en asociación de Policy | Operación Azure lenta (normal) | Esperar hasta 30 min (automático) |

---

## 🔐 Notas de seguridad

> ⚠️ **Este despliegue es para entorno de pruebas/educativo.**

- Las reglas permiten tráfico desde `*` (cualquier IP). En producción, restringir a IPs conocidas.
- La contraseña de Windows está en texto plano en el script. Usar Azure Key Vault en producción.
- Las VMs no tienen IP pública (buena práctica), todo el acceso pasa por el Firewall.
- El UDR fuerza todo el tráfico saliente por el Firewall (inspección centralizada).

---

## 📁 Archivos

| Archivo | Descripción |
|---------|-------------|
| `deploy-azure-completo.sh` | Script principal de despliegue |
| `README.md` | Esta documentación |
| `~/deploy-azure-completo.log` | Log de ejecución (generado al ejecutar) |
