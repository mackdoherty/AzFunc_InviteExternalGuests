param([byte[]] $InputBlob, $TriggerMetadata)

# ── Parse blob content ─────────────────────────────────────────────────────
$content = [System.Text.Encoding]::UTF8.GetString($InputBlob)
$lines   = $content -split "\r?\n" | ForEach-Object { $_.Trim() }

# ── Read optional config headers from the file ─────────────────────────────
# Supported headers (must appear before any email addresses):
#   # company: Contoso Ltd
#   # sponsor: 00000000-0000-0000-0000-000000000000
$fileCompany = ($lines | Where-Object { $_ -match '^#\s*company\s*:\s*(.+)' } | Select-Object -First 1) -replace '^#\s*company\s*:\s*', ''
$fileSponsor = ($lines | Where-Object { $_ -match '^#\s*sponsor\s*:\s*(.+)' } | Select-Object -First 1) -replace '^#\s*sponsor\s*:\s*', ''

$companyName = if ($fileCompany) { $fileCompany } else { $env:GUEST_COMPANY_NAME }
$sponsorId   = if ($fileSponsor) { $fileSponsor } else { $env:GUEST_SPONSOR_ID }

$emails = $lines | Where-Object { $_ -match '@' }

if ($emails.Count -eq 0) {
    Write-Host "No valid email addresses found in blob: $($TriggerMetadata.Name)"
    return
}

Write-Host "Processing $($emails.Count) email(s) from blob: $($TriggerMetadata.Name)"

# ── Acquire Graph API token via Managed Identity ──────────────────────────
try {
    $tokenResponse = Invoke-RestMethod `
        -Uri     "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com/&api-version=2019-08-01" `
        -Headers @{ "X-IDENTITY-HEADER" = $env:IDENTITY_HEADER } `
        -Method  Get

    $accessToken = $tokenResponse.access_token
} catch {
    Write-Error "Failed to acquire Managed Identity token: $($_.Exception.Message)"
    throw
}

$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# ── Process each email ─────────────────────────────────────────────────────
$results = @()

foreach ($email in $emails) {

    $localPart = $email.Split("@")[0]
    $nameParts = $localPart.Split(".")

    if ($nameParts.Count -lt 2) {
        Write-Warning "Skipping '$email' — cannot parse first/last name."
        $results += @{ email = $email; status = "skipped"; reason = "Cannot parse first/last name from address" }
        continue
    }

    $culture     = [System.Globalization.CultureInfo]::CurrentCulture
    $firstName   = $culture.TextInfo.ToTitleCase($nameParts[0].ToLower())
    $lastName    = $culture.TextInfo.ToTitleCase(($nameParts[1..($nameParts.Count-1)] -join " ").ToLower())
    $displayName = "$firstName $lastName ($companyName)"

    $invitePayload = @{
        invitedUserEmailAddress = $email
        inviteRedirectUrl       = "https://myapps.microsoft.com"
        sendInvitationMessage   = $false
        invitedUserDisplayName  = $displayName
        invitedUserType         = "Guest"
    } | ConvertTo-Json -Depth 5

    try {
        $inviteResponse = Invoke-RestMethod `
            -Method  Post `
            -Uri     "https://graph.microsoft.com/v1.0/invitations" `
            -Headers $headers `
            -Body    $invitePayload

        $userId = $inviteResponse.invitedUser.id

        $patchPayload = @{
            givenName   = $firstName
            surname     = $lastName
            companyName = $companyName
            displayName = $displayName
        } | ConvertTo-Json

        $null = Invoke-RestMethod `
            -Method  Patch `
            -Uri     "https://graph.microsoft.com/v1.0/users/$userId" `
            -Headers $headers `
            -Body    $patchPayload

        if ($sponsorId) {
            $sponsorPayload = @{
                "@odata.id" = "https://graph.microsoft.com/v1.0/users/$sponsorId"
            } | ConvertTo-Json

            $null = Invoke-RestMethod `
                -Method  Post `
                -Uri     "https://graph.microsoft.com/v1.0/users/$userId/sponsors/`$ref" `
                -Headers $headers `
                -Body    $sponsorPayload
        }

        Write-Host "✓ Invited: $displayName ($email)"
        $results += @{
            email       = $email
            status      = "invited"
            userId      = $userId
            displayName = $displayName
        }

    } catch {
        $errMsg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-Warning "✗ Failed: $email — $errMsg"
        $results += @{ email = $email; status = "failed"; reason = $errMsg }
    }
}

# ── Summary ────────────────────────────────────────────────────────────────
$succeeded = ($results | Where-Object { $_.status -eq "invited" }).Count
$failed    = ($results | Where-Object { $_.status -eq "failed" }).Count
$skipped   = ($results | Where-Object { $_.status -eq "skipped" }).Count

Write-Host "Complete — Invited: $succeeded | Failed: $failed | Skipped: $skipped"