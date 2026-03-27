# ☁️ Curso de Arquitectura de Nube

Repositorio de laboratorios del **Curso de Arquitectura de Nube**, dictado por **Estud-IA**.

---

## 📂 Contenido

| Laboratorio | Descripción |
|---|---|
| [VM+Firewall](VM+Firewall/) | Despliegue automatizado de infraestructura Azure con Azure Firewall, máquinas virtuales, DNAT, UDR y Firewall Policy. |
| [Balanceador de carga](Balanceador%20de%20carga/) | Azure Load Balancer (Standard) con dos VMs Linux, Nginx, Health Probe y NAT Rules para SSH. |
| [Application Gateway](Aplication%20Gateway/) | Azure Application Gateway (Standard V2) con enrutamiento por URL hacia dos backends (imágenes y videos). |
| [Firewall + Load Balancer + Backup](Firewall+Load_Balancer+Backup/) | Azure Firewall (Basic) con DNAT, Load Balancer interno, 2 VMs Linux + Nginx y Recovery Services con backup. |

---

## 🎯 Objetivo

Este repositorio reúne los ejercicios prácticos (laboratorios) desarrollados durante el curso, donde se exploran conceptos clave de arquitectura en la nube como:

- Redes virtuales y subredes
- Máquinas virtuales (Linux y Windows)
- Firewalls y políticas de seguridad
- Enrutamiento definido por el usuario (UDR)
- Traducción de direcciones de red (DNAT)
- Balanceadores de carga y alta disponibilidad
- Application Gateway y enrutamiento basado en URL
- Recovery Services y backup de máquinas virtuales
- Automatización de infraestructura con scripts

---

## 🚀 Cómo usar

Cada carpeta contiene su propio `README.md` con instrucciones específicas de despliegue y uso.

### Cargar scripts en Azure Cloud Shell

**Opción 1 — Clonar el repositorio directamente:**
```bash
git clone https://github.com/qwermk/Curso-Arquitectura-Nube.git
cd Curso-Arquitectura-Nube
```

**Opción 2 — Subir archivos manualmente:**
1. Abrir [Azure Cloud Shell](https://shell.azure.com) (Bash)
2. Hacer clic en el ícono **📤 Cargar/Descargar archivos** en la barra de herramientas
3. Seleccionar **Cargar** y elegir el script `.sh` desde tu equipo
4. El archivo se sube a `$HOME/` — ejecutar con:
```bash
chmod +x ~/nombre_del_script.sh
bash ~/nombre_del_script.sh
```

**Opción 3 — Copiar y pegar desde GitHub:**
1. Abrir el script en GitHub y copiar todo el contenido
2. En Azure Cloud Shell, crear el archivo:
```bash
nano nombre_del_script.sh
```
3. Pegar el contenido, guardar con `Ctrl+O` y salir con `Ctrl+X`
4. Ejecutar:
```bash
chmod +x nombre_del_script.sh
bash nombre_del_script.sh
```

> ⚠️ **NO** ejecutar los scripts con `source` (si hay error, cierra la sesión de Cloud Shell).

---

## 📄 Licencia

Material educativo del curso de Arquitectura de Nube — Estud-IA.
