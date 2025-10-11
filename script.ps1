<#
.SYNOPSIS
    Compares your Steam wishlist with the games owned by your friends AND the friends of your specified family members.

.DESCRIPTION
    This script performs the following steps:
    1. Fetches the primary user's Steam wishlist.
    2. Fetches the friend lists for the primary user AND for each specified family member.
    3. Creates a single, de-duplicated master list of all unique friends.
    4. Fetches profile names for all unique friends, correctly handling more than 100 friends by batching API requests.
    5. For each unique friend, fetches their list of owned games.
    6. Compares the friend's owned games with the primary user's wishlist.
    7. Outputs a single, consolidated ranked list of ALL friends, including those with zero matches or private profiles.
    8. Creates a detailed text file ('wishlist_matches.txt') with the results, fetching missing game names if necessary.

.NOTES
    - Your Steam profile and your family's profiles must be public to fetch their friend lists.
    - Friends with private profiles or no owned games will be flagged in the report.
    - You must provide your own Steam Web API Key and your 64-bit SteamID.
#>

#region -------------------------- CONFIGURATION --------------------------
# Paste your unique Steam Web API key below.
# Get one here: https://steamcommunity.com/dev/apikey
$apiKey = "YOUR_API_KEY_HERE"

# Paste YOUR 64-bit SteamID below. The script will use YOUR wishlist as the reference.
$mySteamID = "YOUR_STEAM_ID_HERE"

# --- NEW: Add up to four family member SteamIDs here ---
# The script will also check the friends of these users.
# Example: $familySteamIDs = @("76561198000000001", "76561198000000002")
$familySteamIDs = @(
    "FAMILY_MEMBER_1_STEAM_ID",
    "FAMILY_MEMBER_2_STEAM_ID"
    # Add other family SteamIDs here, each in quotes and separated by a comma
)

# --- Define the output filename for the detailed report ---
$outputFileName = "wishlist_matches.txt"
#endregion ------------------------------------------------------------------

# --- Script starts here, no need to edit below this line ---

# Check for placeholder values
if ($apiKey -eq "YOUR_API_KEY" -or $mySteamID -eq "YOUR_STEAM_ID") {
    Write-Host "ERROR: Please replace 'YOUR_API_KEY' and 'YOUR_STEAM_ID' with your actual Steam details in the script." -ForegroundColor Red
    exit
}

# Function to handle API calls with error checking
function Invoke-SteamApiRequest {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Uri
    )
    try {
        return Invoke-RestMethod -Uri $Uri -Method Get -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to fetch data from URI: $Uri"
        Write-Warning "Error message: $($_.Exception.Message)"
        return $null
    }
}

# --- STEP 1: Fetch YOUR wishlist and create a game name map ---
Write-Host "Fetching your wishlist (ID: $mySteamID)..." -ForegroundColor Cyan
# API Endpoint Reference: https://steamapi.xpaw.me/#IWishlistService/GetWishlist
$wishlistUrl = "https://api.steampowered.com/IWishlistService/GetWishlist/v1/?key=$($apiKey)&steamid=$($mySteamID)"
$wishlistResponse = Invoke-SteamApiRequest -Uri $wishlistUrl

if (-not $wishlistResponse.response.items) {
    Write-Host "Could not fetch your wishlist. It might be private, the API key could be invalid, or the SteamID is incorrect." -ForegroundColor Red
    exit
}

# Create a lookup table for AppID -> Game Name and a list of AppIDs
$wishlistGameMap = @{}
$wishlistResponse.response.items | ForEach-Object {
    $wishlistGameMap[$_.appid] = $_.name
}
$wishlistAppIDs = $wishlistResponse.response.items.appid

# --- STEP 2: Aggregate friend lists from you and your family ---
Write-Host "Fetching friend lists for you and family members..." -ForegroundColor Cyan
$allSteamIDsToQuery = @($mySteamID) + $familySteamIDs
$allUniqueFriendObjects = @{} # Using a hashtable to automatically handle duplicates

foreach ($steamID in $allSteamIDsToQuery) {
    Write-Host " - Getting friends for ID: $steamID"
    # API Endpoint Reference: https://steamapi.xpaw.me/#ISteamUser/GetFriendList
    $friendsListUrl = "https://api.steampowered.com/ISteamUser/GetFriendList/v1/?key=$($apiKey)&steamid=$($steamID)"
    $friendsListResponse = Invoke-SteamApiRequest -Uri $friendsListUrl
    
    if ($friendsListResponse.friendslist.friends) {
        foreach ($friend in $friendsListResponse.friendslist.friends) {
            # If the friend is not already in our master list, add them.
            if (-not $allUniqueFriendObjects.ContainsKey($friend.steamid)) {
                $allUniqueFriendObjects[$friend.steamid] = $friend
            }
        }
    } else {
        Write-Warning "Could not fetch friend list for $steamID. Profile may be private."
    }
}

# Convert the hashtable of unique friends back into an array for processing
$friends = $allUniqueFriendObjects.Values
if ($friends.Count -eq 0) {
    Write-Host "No friends could be found for any of the specified Steam users." -ForegroundColor Red
    exit
}

# --- STEP 3: Fetch profile names in batches of 100 ---
Write-Host "Fetching profile names for $($friends.Count) unique friends..." -ForegroundColor Cyan
$steamIdToNameMap = @{}
$allFriendSteamIDs = $friends.steamid
$batchSize = 100

for ($i = 0; $i -lt $allFriendSteamIDs.Count; $i += $batchSize) {
    # Get a chunk of up to 100 IDs
    $idChunk = $allFriendSteamIDs[$i..($i + $batchSize - 1)]
    $friendSteamIDsString = $idChunk -join ','
    
    # API Endpoint Reference: https://steamapi.xpaw.me/#ISteamUser/GetPlayerSummaries
    $playerSummariesUrl = "https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=$($apiKey)&steamids=$($friendSteamIDsString)"
    $playerSummariesResponse = Invoke-SteamApiRequest -Uri $playerSummariesUrl
    
    if ($playerSummariesResponse.response.players) {
        $playerSummariesResponse.response.players | ForEach-Object {
            $steamIdToNameMap[$_.steamid] = $_.personaname
        }
    }
}

# --- STEP 4: Iterate through the master friend list, fetch owned games, and compare ---
$friendRanking = @()
$totalFriends = $friends.Count
$currentFriend = 0

Write-Host "Analyzing games for $($totalFriends) unique friends. This may take a moment..." -ForegroundColor Cyan
foreach ($friend in $friends) {
    $currentFriend++
    # Use a default name if the lookup fails for any reason
    $friendName = if ($steamIdToNameMap.ContainsKey($friend.steamid)) { $steamIdToNameMap[$friend.steamid] } else { "Unknown (ID: $($friend.steamid))" }
    
    Write-Progress -Activity "Checking friends' libraries" -Status "Processing: $friendName ($currentFriend/$totalFriends)" -PercentComplete ($currentFriend / $totalFriends * 100)

    # API Endpoint Reference: https://steamapi.xpaw.me/#IPlayerService/GetOwnedGames
    $ownedGamesUrl = "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/?key=$($apiKey)&steamid=$($friend.steamid)&include_appinfo=false"
    $ownedGamesResponse = Invoke-SteamApiRequest -Uri $ownedGamesUrl

    $matchingAppIDs = @()
    $status = "OK" # Default status

    # Check if we can access the friend's game library. If not, flag their status.
    if (-not $ownedGamesResponse.response.games) {
        $status = "Private Profile or No Games"
    }
    else {
        # If games are accessible, compare them to the wishlist
        $ownedGameAppIDs = $ownedGamesResponse.response.games.appid
        $matchingAppIDs = (Compare-Object -ReferenceObject $wishlistAppIDs -DifferenceObject $ownedGameAppIDs -IncludeEqual -ExcludeDifferent | Select-Object -ExpandProperty InputObject)
        if ($matchingAppIDs.Count -eq 0) {
            $status = "No Matching Games"
        }
    }
    
    # MODIFICATION: Always add the friend to the ranking object, regardless of match count.
    $friendRanking += [PSCustomObject]@{
        FriendName     = $friendName
        MatchingGames  = $matchingAppIDs.Count # This will be 0 if private or no matches
        MatchingAppIDs = $matchingAppIDs
        Status         = $status
    }
}

# --- STEP 5: Sort the results and display the final ranking ---
Write-Host "`n--- Combined Wishlist Match Ranking ---`n" -ForegroundColor Green

$sortedRanking = $friendRanking | Sort-Object -Property MatchingGames -Descending

if ($sortedRanking.Count -eq 0) {
    Write-Host "Analysis complete, but no friends could be processed." -ForegroundColor Yellow
}
else {
    $rank = 1
    foreach ($entry in $sortedRanking) {
        # Using Trim() to remove potential whitespace issues from the name
        $displayName = "$($rank). $($entry.FriendName.Trim()) - $($entry.MatchingGames) matching games"
        
        # MODIFICATION: Add status text for friends with 0 matches
        if ($entry.MatchingGames -eq 0) {
            $displayName += " ($($entry.Status))"
        }
        
        Write-Host $displayName
        $rank++
    }
}

# --- STEP 6: Generate and save the detailed report file ---
Write-Host "`nGenerating detailed report..." -ForegroundColor Cyan
$fileContent = @()
$fileContent += "--- Steam Wishlist Match Report ---"
$fileContent += "Generated on: $(Get-Date)"
$fileContent += ""

if ($sortedRanking.Count -eq 0) {
    $fileContent += "No friends found to generate a report."
}
else {
    foreach ($entry in $sortedRanking) {
        # Add a header for the friend
        $fileContent += "----------------------------------------"
        $fileContent += "$($entry.FriendName.Trim()) ($($entry.MatchingGames) Matches)"
        $fileContent += "----------------------------------------"
        
        if ($entry.MatchingGames -gt 0) {
            # List each matching game for that friend
            foreach ($appId in $entry.MatchingAppIDs) {
                
                #region =========== MODIFICATION START ===========
                # Try to get the game name from our initial wishlist map.
                $gameName = $wishlistGameMap[$appId]
                
                $appDetailsUrl = "https://store.steampowered.com/api/appdetails?appids=$($appId)"
                $appDetailsResponse = Invoke-SteamApiRequest -Uri $appDetailsUrl
                
                # The response key is the AppID itself. We need to access it dynamically.
                $appData = $appDetailsResponse.PSObject.Properties[$appId].Value
                
                if ($appData.success -and -not [string]::IsNullOrWhiteSpace($appData.data.name)) {
                    $gameName = $appData.data.name
                    # Cache the name so we don't have to fetch it again if another friend has the same game.
                    $wishlistGameMap[$appId] = $gameName
                }
                else {
                    $gameName = "Name Not Found"
                }
                
                # Format the line exactly as you requested.
                $fileContent += "   - (AppID: $($appId)) $($gameName)"
                #endregion ======== MODIFICATION END ==========
            }
        }
        else {
            # If there are no matches, print the reason.
            $fileContent += "   - $($entry.Status)"
        }
        $fileContent += "" # Add a blank line for readability
    }
}

try {
    $fileContent | Out-File -FilePath $outputFileName -Encoding utf8 -ErrorAction Stop
    Write-Host "Successfully saved detailed report to: $outputFileName" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Could not write to file '$($outputFileName)'." -ForegroundColor Red
    Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
}