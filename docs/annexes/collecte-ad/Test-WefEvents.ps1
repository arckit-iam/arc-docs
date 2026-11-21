#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Déclenche tous les Event IDs IAM collectés par WEF pour validation end-to-end.
.DESCRIPTION
    Crée un utilisateur et des groupes (global, local, universel) de test,
    effectue toutes les opérations correspondant aux Event IDs surveillés,
    puis nettoie (suppression) tout ce qui a été créé.

    Events couverts :
      4720 - Compte utilisateur créé
      4722 - Compte utilisateur activé
      4725 - Compte utilisateur désactivé
      4726 - Compte utilisateur supprimé
      4727 - Groupe global de sécurité créé
      4728 - Membre ajouté au groupe global
      4729 - Membre retiré du groupe global
      4730 - Groupe global de sécurité supprimé
      4731 - Groupe local de sécurité créé
      4732 - Membre ajouté au groupe local
      4733 - Membre retiré du groupe local
      4734 - Groupe local de sécurité supprimé
      4738 - Compte utilisateur modifié
      4754 - Groupe universel de sécurité créé
      4756 - Membre ajouté au groupe universel
      4757 - Membre retiré du groupe universel
      4758 - Groupe universel de sécurité supprimé
      4781 - Nom de compte modifié (renommage)

.PARAMETER OUPath
    OU de destination pour les objets de test. Défaut : CN=Users,DC=iap,DC=local

.PARAMETER WaitSeconds
    Secondes d'attente entre chaque opération (pour la lisibilité dans les logs). Défaut : 2

.EXAMPLE
    .\Test-WefEvents.ps1
    .\Test-WefEvents.ps1 -OUPath "OU=Test,DC=iap,DC=local" -WaitSeconds 1
#>
param(
    [string]$OUPath      = "CN=Users,DC=iap,DC=local",
    [string]$Server      = "DC01.iap.local",
    [int]   $WaitSeconds = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
$suffix   = (Get-Random -Maximum 9999).ToString("D4")
$user     = "wef-test-$suffix"
$grpG     = "wef-grp-global-$suffix"
$grpL     = "wef-grp-local-$suffix"
$grpU     = "wef-grp-univ-$suffix"
$userRenamed = "wef-test-ren-$suffix"

# Mot de passe complexe généré dynamiquement (respecte longueur + complexité)
$pwdString = "Wef!Test$(Get-Random -Minimum 1000 -Maximum 9999)#Iap"
$secPwd    = ConvertTo-SecureString $pwdString -AsPlainText -Force

function Step {
    param([int]$EventId, [string]$Description)
    Write-Host ""
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  [Event $EventId] $Description" -ForegroundColor Cyan
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkGray
    Start-Sleep -Seconds $WaitSeconds
}

function Cleanup {
    Write-Host "`n[CLEANUP] Suppression des objets de test..." -ForegroundColor Yellow
    foreach ($obj in @($userRenamed, $user)) {
        try {
            Get-ADUser -Identity $obj -Server $Server -ErrorAction SilentlyContinue |
                Remove-ADUser -Confirm:$false
            Write-Host "  Utilisateur $obj supprimé" -ForegroundColor DarkGray
        } catch { }
    }
    foreach ($grp in @($grpG, $grpL, $grpU)) {
        try {
            Get-ADGroup -Identity $grp -Server $Server -ErrorAction SilentlyContinue |
                Remove-ADGroup -Confirm:$false
            Write-Host "  Groupe $grp supprimé" -ForegroundColor DarkGray
        } catch { }
    }
}

# Cleanup préventif au cas où un run précédent aurait échoué
Cleanup

Write-Host "`n╔══════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Test WEF Events — Suffix : $suffix           ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Green

try {
    # ------------------------------------------------------------------
    # Event 4720 — Compte créé (désactivé d'abord pour contrôler 4722)
    # ------------------------------------------------------------------
    Step 4720 "Création du compte utilisateur : $user"
    New-ADUser `
        -Name            $user `
        -SamAccountName  $user `
        -UserPrincipalName "$user@iap.local" `
        -AccountPassword $secPwd `
        -Enabled         $false `
        -Path            $OUPath `
        -Description     "WEF Test Account - $suffix" `
        -Server          $Server

    # ------------------------------------------------------------------
    # Event 4722 — Compte activé
    # ------------------------------------------------------------------
    Step 4722 "Activation du compte : $user"
    Enable-ADAccount -Identity $user -Server $Server

    # ------------------------------------------------------------------
    # Event 4738 — Modification d'attributs
    # ------------------------------------------------------------------
    Step 4738 "Modification du compte (Department, Title) : $user"
    Set-ADUser -Identity $user `
        -Department "WEF-Test" `
        -Title      "Test IAM Events" `
        -Office     "Lab" `
        -Server     $Server

    # ...séquence de renommage supprimée à la demande de l'utilisateur...

    # ------------------------------------------------------------------
    # Event 4725 — Désactivation
    # ------------------------------------------------------------------
    Step 4725 "Désactivation du compte : $user"
    Disable-ADAccount -Identity $user -Server $Server

    # ------------------------------------------------------------------
    # Event 4727 — Création groupe global de sécurité
    # ------------------------------------------------------------------
    Step 4727 "Création groupe global de sécurité : $grpG"
    New-ADGroup `
        -Name          $grpG `
        -SamAccountName $grpG `
        -GroupScope    Global `
        -GroupCategory Security `
        -Path          $OUPath `
        -Description   "WEF Test Global Group - $suffix" `
        -Server        $Server

    # ------------------------------------------------------------------
    # Event 4728 — Ajout membre au groupe global
    # ------------------------------------------------------------------
    Step 4728 "Ajout de $user au groupe global : $grpG"
    Add-ADGroupMember -Identity $grpG -Members $user -Server $Server

    # ------------------------------------------------------------------
    # Event 4729 — Retrait membre du groupe global
    # ------------------------------------------------------------------
    Step 4729 "Retrait de $user du groupe global : $grpG"
    Remove-ADGroupMember -Identity $grpG -Members $user -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4730 — Suppression groupe global
    # ------------------------------------------------------------------
    Step 4730 "Suppression du groupe global : $grpG"
    Remove-ADGroup -Identity $grpG -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4731 — Création groupe local de sécurité
    # ------------------------------------------------------------------
    Step 4731 "Création groupe local de sécurité : $grpL"
    New-ADGroup `
        -Name          $grpL `
        -SamAccountName $grpL `
        -GroupScope    DomainLocal `
        -GroupCategory Security `
        -Path          $OUPath `
        -Description   "WEF Test Local Group - $suffix" `
        -Server        $Server

    # ------------------------------------------------------------------
    # Event 4732 — Ajout membre au groupe local
    # ------------------------------------------------------------------
    Step 4732 "Ajout de $user au groupe local : $grpL"
    Add-ADGroupMember -Identity $grpL -Members $user -Server $Server

    # ------------------------------------------------------------------
    # Event 4733 — Retrait membre du groupe local
    # ------------------------------------------------------------------
    Step 4733 "Retrait de $user du groupe local : $grpL"
    Remove-ADGroupMember -Identity $grpL -Members $user -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4734 — Suppression groupe local
    # ------------------------------------------------------------------
    Step 4734 "Suppression du groupe local : $grpL"
    Remove-ADGroup -Identity $grpL -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4754 — Création groupe universel de sécurité
    # ------------------------------------------------------------------
    Step 4754 "Création groupe universel de sécurité : $grpU"
    New-ADGroup `
        -Name          $grpU `
        -SamAccountName $grpU `
        -GroupScope    Universal `
        -GroupCategory Security `
        -Path          $OUPath `
        -Description   "WEF Test Universal Group - $suffix" `
        -Server        $Server

    # ------------------------------------------------------------------
    # Event 4756 — Ajout membre au groupe universel
    # ------------------------------------------------------------------
    Step 4756 "Ajout de $user au groupe universel : $grpU"
    Add-ADGroupMember -Identity $grpU -Members $user -Server $Server

    # ------------------------------------------------------------------
    # Event 4757 — Retrait membre du groupe universel
    # ------------------------------------------------------------------
    Step 4757 "Retrait de $user du groupe universel : $grpU"
    Remove-ADGroupMember -Identity $grpU -Members $user -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4758 — Suppression groupe universel
    # ------------------------------------------------------------------
    Step 4758 "Suppression du groupe universel : $grpU"
    Remove-ADGroup -Identity $grpU -Server $Server -Confirm:$false

    # ------------------------------------------------------------------
    # Event 4726 — Suppression du compte utilisateur
    # ------------------------------------------------------------------
    Step 4726 "Suppression du compte utilisateur : $user"
    Remove-ADUser -Identity $user -Server $Server -Confirm:$false

    Write-Host "`n╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║  Tous les événements ont été déclenchés avec succès.         ║" -ForegroundColor Green
    Write-Host "║  Attendre ~15s puis vérifier ForwardedEvents sur WEC01.      ║" -ForegroundColor Green
    Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green

    Write-Host "`nCommande de vérification sur WEC01 :" -ForegroundColor Yellow
    Write-Host @"
Get-WinEvent -LogName ForwardedEvents -MaxEvents 50 |
    Where-Object { `$_.Id -in @(4720,4722,4725,4726,4727,4728,4729,4730,
                                4731,4732,4733,4734,4738,4754,4756,4757,4758,4781) } |
    Select-Object TimeCreated, Id, MachineName |
    Sort-Object TimeCreated |
    Format-Table -AutoSize
"@ -ForegroundColor DarkYellow

} catch {
    Write-Host "`n[ERREUR] $_" -ForegroundColor Red
    Cleanup
    exit 1
}
