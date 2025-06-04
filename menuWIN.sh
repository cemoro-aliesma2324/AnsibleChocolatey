#!/bin/bash

# ------------------------------------------------------------------------------
#   Script interactivo para gestionar Windows Update con Ansible
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
#   Añade un host al grupo [tmp] solicitando un alias al principio
# ------------------------------------------------------------------------------
add_to_tmp_group() {
    local host_ip="$1" user="$2" pass="$3"
    read -p "Alias para ${host_ip} (sin espacios): " host_alias
    local line="${host_alias} ansible_host=${host_ip} ansible_user=${user} ansible_password=${pass} ansible_connection=ssh"

    # Crear [tmp] si no existe
    if ! grep -q '^\[tmp\]' "$INVENTORY_FILE"; then
        echo "" | sudo tee -a "$INVENTORY_FILE" >/dev/null
        echo "[tmp]" | sudo tee -a "$INVENTORY_FILE" >/dev/null
    fi
    # Insertar la línea tras [tmp] si no existe
    if ! grep -q "^${host_alias} " "$INVENTORY_FILE"; then
        sudo sed -i "/^\[tmp\]/a ${line}" "$INVENTORY_FILE"
    fi
    echo "$host_alias"
}

# ------------------------------------------------------------------------------
#   Mueve un host de [tmp] a otro grupo existente
# ------------------------------------------------------------------------------
move_tmp_to_group() {
    local host_alias="$1" dest_group="$2"
    # Extraer la línea con alias
    host_line="$(awk "/^\[tmp\]/ {flag=1; next} /^\[/ {flag=0} flag && /^${host_alias} / {print}" "$INVENTORY_FILE")"
    if [[ -z "$host_line" ]]; then
        echo "No encontrado ${host_alias} en [tmp]."
        return 1
    fi
    # Borrar de [tmp]
    sudo sed -i "/^\[tmp\]/, /^\[/ {/^${host_alias} /d}" "$INVENTORY_FILE"
    # Añadir a grupo destino
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
#   Ejecuta el playbook de Windows Update según elección
# ------------------------------------------------------------------------------
run_update_playbook() {
    local playbook="$1"
    local info; info=$(select_target) || return 1
    IFS=':' read -r type subtype arg <<< "$info"
    [[ "$type" == "group" ]] && arg="$subtype"

    local inventory_args=( -i "$INVENTORY_FILE" )
    local ansible_args=()
    local new_alias new_ip new_user new_pass

    case "$type" in
        all) ;;
        group) ansible_args+=(--limit "${arg}") ;;
        host)
            if [[ "$subtype" == "new" ]]; then
                check_sshpass
                new_ip="$arg"
                read -p "Usuario para ${new_ip}: " new_user
                read -s -p "Contraseña: " new_pass; echo
                new_alias=$(add_to_tmp_group "$new_ip" "$new_user" "$new_pass")
                ansible_args+=(--limit tmp)
            else
                ansible_args+=(--limit "${arg}")
            fi
            ;;
    esac

    if [[ ! -f "$playbook" ]]; then
        echo "Playbook '$playbook' no encontrado."; read -p "Enter..."; return 1
    fi

    echo -e "\n=== EJECUTANDO: ${playbook} ==="
    echo "ansible-playbook ${inventory_args[*]} ${ansible_args[*]} $playbook"
    ansible-playbook "${inventory_args[@]}" "${ansible_args[@]}" "$playbook"
    echo

    if [[ "$subtype" == "new" ]]; then
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
#   Menú principal de Windows Update
# ------------------------------------------------------------------------------
while true; do
    clear
    cat <<EOF
=====================================
        Windows Update                
=====================================
1) Descargar Actualizaciones (Sin instalar)
2) Instalar Actualizaciones (Descargadas)
3) Descargar e Instalar CON Reinicio
4) Descargar e Instalar SIN Reinicio
5) Salir
=====================================
EOF
    read -p "Seleccione una opción [1-5]: " opcion
    case $opcion in
        1) run_update_playbook "$SCRIPT_DIR/playbooks/downloadUpdates.yml" ;;
        2) run_update_playbook "$SCRIPT_DIR/playbooks/installUpdates.yml" ;;
        3) run_update_playbook "$SCRIPT_DIR/playbooks/rebootUpdates.yml" ;;
        4)
            run_update_playbook "$SCRIPT_DIR/playbooks/downloadUpdates.yml" && \
            run_update_playbook "$SCRIPT_DIR/playbooks/installUpdates.yml"
            ;;
        5) echo "Saliendo..."; exit 0 ;;
        *) echo "Opción inválida."; sleep 1 ;;
    esac
done

