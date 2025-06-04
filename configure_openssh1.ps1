# Requiere ejecución como Administrador
# Guardar como 'configure_openssh.ps1' y ejecutar: .\configure_openssh.ps1

# 1. Instalar OpenSSH Server
if (-not (Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' -and $_.State -eq 'Installed' })) {
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
}

# 2. Iniciar y configurar el servicio SSH
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# 3. Configurar Firewall
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "OpenSSH-Server" -DisplayName "OpenSSH Server" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# 4. Configurar archivo sshd_config
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Copy-Item $sshdConfig "$sshdConfig.bak" -Force  # Backup

@"
# Configuración para Ansible
Port 22
ListenAddress 0.0.0.0
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Seguridad
PermitEmptyPasswords no
PermitRootLogin no
"@ | Set-Content $sshdConfig -Force

# 5. Crear directorio .ssh y asignar permisos
$sshDir = "C:\Users\$env:USERNAME\.ssh"
New-Item -Path $sshDir -ItemType Directory -Force -ErrorAction SilentlyContinue

# Permisos usando Set-Acl (compatible con cualquier idioma)
$acl = Get-Acl $sshDir
$acl.SetAccessRuleProtection($true, $false)  # Deshabilita herencia
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $env:USERNAME,
    "FullControl",
    "ContainerInherit, ObjectInherit",
    "None",
    "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl -Path $sshDir -AclObject $acl

# 6. Crear archivo authorized_keys y permisos
$authorizedKeys = "$sshDir\authorized_keys"
New-Item -Path $authorizedKeys -ItemType File -Force

$aclFile = Get-Acl $authorizedKeys
$aclFile.SetAccessRuleProtection($true, $false)
$ruleFile = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $env:USERNAME,
    "Read",
    "Allow"
)
$aclFile.AddAccessRule($ruleFile)
Set-Acl -Path $authorizedKeys -AclObject $aclFile

# 7. Reiniciar servicio SSH
Restart-Service sshd

# 8. Instalar Python para Ansible (requerido)
if (-not (Test-Path "C:\Python39")) {
    Invoke-WebRequest -Uri "https://www.python.org/ftp/python/3.9.13/python-3.9.13-amd64.exe" -OutFile "$env:TEMP\python-installer.exe"
    Start-Process "$env:TEMP\python-installer.exe" -ArgumentList '/quiet InstallAllUsers=1 PrependPath=1' -Wait
}

# Mensaje final
Write-Host "`nConfiguracion completada! Sigue estos pasos desde Kali Linux:" -ForegroundColor Green
Write-Host "
1. Genera una clave SSH en Kali:
   ssh-keygen -t ed25519

2. Copia la clave publica a Windows:
   ssh-copy-id -i ~/.ssh/id_ed25519.pub $env:USERNAME@ip

3. Verifica la conexión sin contraseña:
   ssh $env:USERNAME@ip

4. Ejecuta playbooks de Ansible:
   ansible-playbook -i 'ip,' tu_playbook.yml
" -ForegroundColor Cyan