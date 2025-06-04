#!/bin/bash

# ------------------------------------------------------------------------------
#   Script interactivo para ejecutar playbooks de Ansible y gestionar hosts
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd)"
INVENTORY_FILE="$SCRIPT_DIR/inventories/hosts.ini"

# ------------------------------------------------------------------------------
#   Comprueba que sshpass esté instalado
# ------------------------------------------------------------------------------
check_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        echo "ERROR: 'sshpass' no está instalado. Instálalo con:"
        echo "  Ubuntu/Debian: sudo apt install sshpass"
        echo "  RHEL/CentOS:   sudo yum install sshpass"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
#   Verifica si un host existe en el inventario
# ------------------------------------------------------------------------------
check_in_inventory() {
    local target="$1"
    while IFS= read -r line; do
        [[ "$line" =~ ^# || -z "$line" ]] && continue
        [[ "$line" =~ ^\[.*\]$ ]] && continue
        host_name="$(awk '{print $1}' <<< "$line")"
        ansible_host="$(grep -oP 'ansible_host=\K[^ ]*' <<< "$line" || echo "")"
        if [[ "$host_name" == "$target" || "$ansible_host" == "$target" ]]; then
            echo "$host_name"
            return 0
        fi
    done < "$INVENTORY_FILE"
    return 1
}

# ------------------------------------------------------------------------------
#   Menú de selección de ámbito
# ------------------------------------------------------------------------------
select_target() {
    PS3="Seleccione el ámbito de ejecución: "
    select opt in "Todos los hosts" "Grupo/s" "Un host específico"; do
        case $REPLY in
            1) echo "all"; return 0 ;;  
            2)
                read -p "Ingrese nombre(s) de grupo(s) (separados por comas): " grupos
                IFS=',' read -ra arr <<< "$grupos"
                for g in "${arr[@]}"; do
                    if ! grep -q "^\[${g// /}\]" "$INVENTORY_FILE"; then
                        echo "Error: el grupo '$g' no existe."
                        return 1
                    fi
                done
                echo "group:${grupos}"
                return 0
                ;;
            3)
                read -p "Nombre o IP del host: " host
                if realname="$(check_in_inventory "$host")"; then
                    echo "host:existing:${realname}"
                else
                    echo "host:new:${host}"
                fi
                return 0
                ;;
            *) echo "Opción inválida." ;;
        esac
    done
}

# ------------------------------------------------------------------------------
#   Añade un host al grupo [tmp], solicitando alias
# ------------------------------------------------------------------------------
add_to_tmp_group() {
    local host_ip="$1" user="$2" pass="$3"
    # pedir alias para el host
    read -p "Alias para ${host_ip} (sin espacios): " host_alias
    # construir línea: alias ansible_host=IP ansible_user=... ansible_password=... connection
    local line="${host_alias} ansible_host=${host_ip} ansible_user=${user} ansible_password=${pass} ansible_connection=ssh"

    # crear encabezado [tmp] si no existe
    if ! grep -q '^\[tmp\]' "$INVENTORY_FILE"; then
        echo "" | sudo tee -a "$INVENTORY_FILE" >/dev/null
        echo "[tmp]" | sudo tee -a "$INVENTORY_FILE" >/dev/null
    fi
    # insertar línea tras [tmp] si no existe
    if ! grep -q "^${host_alias} " "$INVENTORY_FILE"; then
        sudo sed -i "/^\[tmp\]/a ${line}" "$INVENTORY_FILE"
    fi
}

# ------------------------------------------------------------------------------
#   Mueve un host de [tmp] a otro grupo existente
# ------------------------------------------------------------------------------
move_tmp_to_group() {
    local host_alias="$1" dest_group="$2"
    # extraer línea
    host_line="$(awk "/^\[tmp\]/ {flag=1; next} /^\[/ {flag=0} flag && /^${host_alias} / {print}" "$INVENTORY_FILE")"
    if [[ -z "$host_line" ]]; then
        echo "No encontrado ${host_alias} en [tmp]."
        return 1
    fi
    # borrar de tmp
    sudo sed -i "/^\[tmp\]/, /^\[/ {/^${host_alias} /d}" "$INVENTORY_FILE"
    # añadir a destino
    if grep -q "^\[${dest_group}\]" "$INVENTORY_FILE"; then
        sudo sed -i "/^\[${dest_group}\]/a ${host_line}" "$INVENTORY_FILE"
    else
        echo "" | sudo tee -a "$INVENTORY_FILE" >/dev/null
        echo "[${dest_group}]" | sudo tee -a "$INVENTORY_FILE" >/dev/null
        echo "${host_line}" | sudo tee -a "$INVENTORY_FILE" >/dev/null
    fi
    echo "Movido ${host_alias} ⇒ [${dest_group}]"
}

# ------------------------------------------------------------------------------
#   Ejecuta playbook y gestiona movimiento final
# ------------------------------------------------------------------------------
run_playbook() {
    local playbook="$1"
    local info; info=$(select_target) || return 1
    IFS=':' read -r type subtype arg <<< "$info"
    [[ "$type" == "group" ]] && arg="$subtype"

    inventory_args=(-i "$INVENTORY_FILE")
    ansible_args=()
    local new_alias new_ip new_user new_pass

    case "$type" in
        all) ;;  # nada que hacer
        group) ansible_args+=(--limit "${arg}") ;;  # grupos
        host)
            if [[ "$subtype" == new ]]; then
                check_sshpass
                new_ip="$arg"
                read -p "Usuario para ${new_ip}: " new_user
                read -s -p "Contraseña: " new_pass; echo
                add_to_tmp_group "$new_ip" "$new_user" "$new_pass"
                # asumimos alias leído en función
                new_alias="$host_alias"
                ansible_args+=(--limit tmp)
            else
                ansible_args+=(--limit "${arg}")
            fi
            ;;
    esac

    # validar playbook
    if [[ ! -f "$playbook" ]]; then
        echo "Playbook '$playbook' no encontrado."; read -p "Enter para continuar..."; return 1
    fi

    echo -e "\n=== EJECUTANDO: ${playbook} ==="
    echo "ansible-playbook ${inventory_args[*]} ${ansible_args[*]} $playbook"
    ansible-playbook "${inventory_args[@]}" "${ansible_args[@]}" "$playbook"
    echo

    # mover host nuevo si procede
    if [[ "$subtype" == new ]]; then
        read -p "¿Mover ${new_alias} de [tmp] a otro grupo? (s/N): " resp
        if [[ "$resp" =~ ^[Ss]$ ]]; then
            echo "Grupos disponibles:"; grep '^\[.*\]' "$INVENTORY_FILE" | sed 's/[][]//g' | grep -v '^tmp$' | nl -w2 -s'. '
            read -p "Grupo destino: " dest
            move_tmp_to_group "$new_alias" "$dest"
        fi
    fi

    read -rsn1 -p "Presione cualquier tecla para volver al menú..."; echo
}

# ------------------------------------------------------------------------------
#   Menú principal
# ------------------------------------------------------------------------------
while true; do
    clear
    cat <<EOF
=====================================
     INSTALACIÓN DE SOFTWARE         
=====================================
0) Instalar Chocolatey
1) Instalar paquete Base (con Adobe)
2) Instalar paquete IT
3) Instalar paquete OT
4) Instalar paquete ING
5) Montar disco Autocad
6) Instalar Microsoft Project 2021
7) Salir
=====================================
EOF
    read -p "Seleccione una opción [0-7]: " opt
    case $opt in
        0) run_playbook "$SCRIPT_DIR/playbooks/chocolatey.yml" ;;  
        1) run_playbook "$SCRIPT_DIR/playbooks/basicPack.yml"   ;;  
        2) run_playbook "$SCRIPT_DIR/playbooks/itPack.yml"      ;;  
        3) run_playbook "$SCRIPT_DIR/playbooks/otPack.yml"      ;;  
        4) run_playbook "$SCRIPT_DIR/playbooks/ingPack.yml"     ;;  
        5) run_playbook "$SCRIPT_DIR/playbooks/autocad.yml"     ;;  
        6) run_playbook "$SCRIPT_DIR/playbooks/project.yml"     ;;  
        7) echo "Saliendo..."; exit 0                              ;;  
        *) echo "Opción inválida."; sleep 1                        ;;  
    esac
done
