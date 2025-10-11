# Steam Family Optimizer

A PowerShell script that compares your Steam wishlist against the game libraries of your friends and the friends of your family members. It helps you quickly find out who in your extended network owns the games you want to play.

## Features

* 🔎 **Comprehensive Search:** Checks the game libraries of your friends AND the friends of specified family members.
* 🔄 **Smart De-duplication:** Creates a single, unique list of all friends to avoid checking the same person multiple times.
* 📊 **Ranked Output:** Displays a simple ranked list in your terminal showing who has the most matching games.
* 📝 **Detailed Reporting:** Generates a `wishlist_matches.txt` file that lists each friend and the specific games they own from your wishlist.
* 🛡️ **Robust:** Gracefully handles friends with private profiles and efficiently queries the Steam API in batches to support large friend lists.

## Prerequisites

1.  **PowerShell:** This is built into modern Windows operating systems.
2.  **A Steam Web API Key:** You can get one for free from the [official Steam page](https://steamcommunity.com/dev/apikey).
3.  **Your 64-bit SteamID:** You will also need the 64-bit SteamIDs for any family members you want to include.

## How to Use

1.  **Download** the `script.ps1` file to your computer.
2.  **Edit the Configuration:** Open the script file in a text editor (like Notepad, VS Code, etc.) and fill in the configuration section at the top:

    ```powershell
    # Paste your unique Steam Web API key below.
    $apiKey = "YOUR_API_KEY_HERE"

    # Paste YOUR 64-bit SteamID below.
    $mySteamID = "YOUR_STEAM_ID_HERE"

    # Add up to four family member SteamIDs here
    $familySteamIDs = @(
        "FAMILY_MEMBER_1_STEAM_ID",
        "FAMILY_MEMBER_2_STEAM_ID"
    )
    ```

3.  **Run the Script:**
    * Open a PowerShell terminal.
    * Navigate to the directory where you saved the script (e.g., `cd C:\Users\YourUser\Downloads`).
    * Run the script by typing `.\script.ps1` and pressing Enter.

    > **Note:** If you get an error about scripts being disabled, run this command first and then try again:
    > `Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process`

## Output Example

The script will first display a ranked summary directly in the terminal:

```text
--- Combined Wishlist Match Ranking ---

1. FriendA - 3 matching games
2. FriendB - 2 matching games
3. FriendC - 0 matching games (Private Profile or No Games)
4. FriendD - 0 matching games (No Matching Games)
```

It will also create a **`wishlist_matches.txt`** file in the same folder with more detail:

```text
--- Steam Wishlist Match Report ---
Generated on: 10/11/2025 20:40:42

----------------------------------------
FriendA (3 Matches)
----------------------------------------
   - (AppID: 413150) Stardew Valley
   - (AppID: 1091500) Cyberpunk 2077
   - (AppID: 271590) Grand Theft Auto V

----------------------------------------
FriendB (2 Matches)
----------------------------------------
   - (AppID: 1086940) Baldur's Gate 3
   - (AppID: 601150) Devil May Cry 5

----------------------------------------
FriendC (0 Matches)
----------------------------------------
   - Private Profile or No Games
```
