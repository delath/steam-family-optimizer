<#
.SYNOPSIS
    Compares your Steam wishlist with the games owned by your friends and family members' friends.

.DESCRIPTION
    Refactored to enforce best practices.
    - Loads configuration from a local .env file.
    - Uses the updated IStoreService/GetAppList/v1 API with pagination to ensure 100% name resolution.
    - Consistently casts AppIDs to integers to prevent dictionary mismatch errors.
#>

[CmdletBinding()]
param()

#region -------------------------- SETUP & ENV PARSING --------------------------
$envFilePath = Join-Path $PSScriptRoot ".env"
$outputFileName = Join-Path $PSScriptRoot "wishlist_matches.txt"

if (-Not (Test-Path $envFilePath)) {
    Write-Host "ERROR: Could not find .env file in the script directory." -ForegroundColor Red
    exit
}

# Parse the .env file
Get-Content $envFilePath | ForEach-Object {
    if ($_ -match '^\s*(?<name>[^#\s=]+)\s*=\s*(?<value>.*)$') {
        $varName = $matches['name']
        $varValue = $matches['value'].Trim('"').Trim("'")
        Set-Variable -Name $varName -Value $varValue -Scope Script
    }
}

# Validate required variables
if ([string]::IsNullOrEmpty($STEAM_API_KEY) -or [string]::IsNullOrEmpty($MY_STEAM_ID)) {
    Write-Host "ERROR: STEAM_API_KEY or MY_STEAM_ID is missing from the .env file." -ForegroundColor Red
    exit
}

# Process Family IDs into an array
$familyIDsArray = @()
if (-Not [string]::IsNullOrEmpty($FAMILY_STEAM_IDS)) {
    $familyIDsArray = $FAMILY_STEAM_IDS -split ',' | ForEach-Object { $_.Trim() }
}
#endregion ----------------------------------------------------------------------

#region -------------------------- HELPER FUNCTIONS -----------------------------
function Invoke-SteamApi {
    param ([string]$Uri)
    try {
        return Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop
    }
    catch {
        Write-Verbose "API Call Failed: $Uri"
        Write-Verbose "Error: $($_.Exception.Message)"
        return $null
    }
}
#endregion ----------------------------------------------------------------------

# --- STEP 1: Fetch Wishlist ---
Write-Host "Fetching your wishlist (ID: $MY_STEAM_ID)..." -ForegroundColor Cyan
$wishlistUrl = "https://api.steampowered.com/IWishlistService/GetWishlist/v1/?key=$STEAM_API_KEY&steamid=$MY_STEAM_ID"
$wishlistResponse = Invoke-SteamApi -Uri $wishlistUrl

if (-not $wishlistResponse.response.items) {
    Write-Host "ERROR: Could not fetch wishlist. Ensure the profile is public." -ForegroundColor Red
    exit
}

$wishlistGameMap = @{}
$wishlistAppIDs = @()

foreach ($item in $wishlistResponse.response.items) {
    $id = [int]$item.appid
    $wishlistAppIDs += $id
    $wishlistGameMap[$id] = $item.name
}

# --- STEP 2: Fetch Global App List (Fixes "Name Not Found") ---
Write-Host "Fetching master list of all Steam apps (paginated)..." -ForegroundColor Cyan
$globalAppListMap = @{}
$lastAppId = 0
$hasMoreApps = $true

while ($hasMoreApps) {
    # Using the new v1 endpoint with pagination limits
    $appListUrl = "https://api.steampowered.com/IStoreService/GetAppList/v1/?key=$STEAM_API_KEY&max_results=50000&last_appid=$lastAppId&include_games=true"
    $appListResponse = Invoke-SteamApi -Uri $appListUrl

    if ($appListResponse -and $appListResponse.response.apps) {
        foreach ($app in $appListResponse.response.apps) {
            $globalAppListMap[[int]$app.appid] = $app.name
        }
        
        if ($appListResponse.response.have_more_results) {
            $lastAppId = $appListResponse.response.last_appid
        } else {
            $hasMoreApps = $false
        }
    } else {
        Write-Warning "Failed to fetch global app list chunk. Some names might still be missing."
        $hasMoreApps = $false
    }
}
Write-Host "Mapped $($globalAppListMap.Count) apps from the Steam database." -ForegroundColor Green

# --- STEP 3: Aggregate Friends ---
Write-Host "Fetching friend lists..." -ForegroundColor Cyan
$allSteamIDsToQuery = @($MY_STEAM_ID) + $familyIDsArray
$uniqueFriendsMap = @{}

foreach ($steamID in $allSteamIDsToQuery) {
    $friendsListUrl = "https://api.steampowered.com/ISteamUser/GetFriendList/v1/?key=$STEAM_API_KEY&steamid=$steamID"
    $friendsResponse = Invoke-SteamApi -Uri $friendsListUrl
    
    if ($friendsResponse.friendslist.friends) {
        foreach ($friend in $friendsResponse.friendslist.friends) {
            if (-not $uniqueFriendsMap.ContainsKey($friend.steamid)) {
                $uniqueFriendsMap[$friend.steamid] = $friend
            }
        }
    } else {
        Write-Warning "Could not fetch friends for $steamID (Profile likely private)."
    }
}

$friends = $uniqueFriendsMap.Values
if ($friends.Count -eq 0) {
    Write-Host "No friends found." -ForegroundColor Red
    exit
}

# --- STEP 4: Fetch Friend Profiles ---
Write-Host "Fetching profile names for $($friends.Count) unique friends..." -ForegroundColor Cyan
$steamIdToNameMap = @{}
$allFriendSteamIDs = $friends.steamid
$batchSize = 100

for ($i = 0; $i -lt $allFriendSteamIDs.Count; $i += $batchSize) {
    $idChunk = $allFriendSteamIDs[$i..($i + $batchSize - 1)] -join ','
    $summaryUrl = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=$STEAM_API_KEY&steamids=$idChunk"
    $summaryResponse = Invoke-SteamApi -Uri $summaryUrl
    
    if ($summaryResponse.response.players) {
        $summaryResponse.response.players | ForEach-Object {
            $steamIdToNameMap[$_.steamid] = $_.personaname
        }
    }
}

# --- STEP 5: Compare Libraries ---
$friendRanking = @()
$totalFriends = $friends.Count
$currentFriend = 0

Write-Host "Analyzing libraries..." -ForegroundColor Cyan
foreach ($friend in $friends) {
    $currentFriend++
    $friendName = if ($steamIdToNameMap.ContainsKey($friend.steamid)) { $steamIdToNameMap[$friend.steamid] } else { "Unknown ($($friend.steamid))" }
    
    Write-Progress -Activity "Comparing Wishlist" -Status "Checking: $friendName" -PercentComplete (($currentFriend / $totalFriends) * 100)

    $ownedGamesUrl = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=$STEAM_API_KEY&steamid=$($friend.steamid)&include_appinfo=false"
    $ownedResponse = Invoke-SteamApi -Uri $ownedGamesUrl

    $matchingAppIDs = @()
    $status = "OK"

    if (-not $ownedResponse.response.games) {
        $status = "Private Library / No Games"
    } else {
        # Cast all owned games to int before comparing
        $ownedGameAppIDs = $ownedResponse.response.games.appid | ForEach-Object { [int]$_ }
        $matchingAppIDs = (Compare-Object -ReferenceObject $wishlistAppIDs -DifferenceObject $ownedGameAppIDs -IncludeEqual -ExcludeDifferent | Select-Object -ExpandProperty InputObject)
        if ($matchingAppIDs.Count -eq 0) {
            $status = "No Matching Games"
        }
    }
    
    $friendRanking += [PSCustomObject]@{
        FriendName     = $friendName.Trim()
        MatchingGames  = @($matchingAppIDs).Count
        MatchingAppIDs = $matchingAppIDs
        Status         = $status
    }
}

# --- STEP 6: Display & Save Report ---
$sortedRanking = $friendRanking | Sort-Object -Property MatchingGames -Descending
Write-Host "`n--- Combined Wishlist Match Ranking ---`n" -ForegroundColor Green

$fileContent = @(
    "--- Steam Wishlist Match Report ---"
    "Generated on: $(Get-Date -Format 'MM/dd/yyyy HH:mm:ss')"
    ""
)

$rank = 1
foreach ($entry in $sortedRanking) {
    $consoleLine = "$rank. $($entry.FriendName) - $($entry.MatchingGames) matches"
    if ($entry.MatchingGames -eq 0) { $consoleLine += " ($($entry.Status))" }
    Write-Host $consoleLine
    $rank++

    $fileContent += "----------------------------------------"
    $fileContent += "$($entry.FriendName) ($($entry.MatchingGames) Matches)"
    $fileContent += "----------------------------------------"
    
    if ($entry.MatchingGames -gt 0) {
        foreach ($id in $entry.MatchingAppIDs) {
            $appId = [int]$id
            $gameName = "Name Not Found"
            
            # 1. Try Wishlist Dictionary
            if ($wishlistGameMap.ContainsKey($appId) -and -not [string]::IsNullOrWhiteSpace($wishlistGameMap[$appId])) {
                $gameName = $wishlistGameMap[$appId]
            } 
            # 2. Try Global Database Dictionary
            elseif ($globalAppListMap.ContainsKey($appId)) {
                $gameName = $globalAppListMap[$appId]
            }
            
            $fileContent += "   - (AppID: $appId) $gameName"
        }
    } else {
        $fileContent += "   - $($entry.Status)"
    }
    $fileContent += ""
}

try {
    $fileContent | Out-File -FilePath $outputFileName -Encoding utf8 -ErrorAction Stop
    Write-Host "`nSuccessfully saved detailed report to: $outputFileName" -ForegroundColor Green
} catch {
    Write-Host "`nERROR: Could not write to $outputFileName" -ForegroundColor Red
}