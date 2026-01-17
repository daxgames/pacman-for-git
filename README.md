# pacman-for-git
Facilitate installing pacman in [Git for Windows](https://github.com/git-for-windows/git/releases), started from this [StackOverflow answer](https://stackoverflow.com/a/65204171).

## How to Update version-tags.txt

### The Easy Way

1. Use `update.ps1 -version <git-version>` as shown below:

    - Multiple matching releases will show a menu as shown below.
    
        ```
        PS C:\src\pacman-for-git> .\update.ps1 -Version 2.41.0
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        Multiple Matching Releases Found Pick One
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        1: v2.41.0.windows.3  - 7/13/2023 11:06:02 PM
        2: v2.41.0.windows.2  - 7/7/2023 10:49:43 AM
        3: v2.41.0.windows.1  - 6/1/2023 5:34:43 PM

        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        Enter number of release to use (1..3, empty to abort): 1

        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        New entries to be added to 'version-tags.txt'.
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        mingw-w64-x86_64-git 2.41.0.3.4a1821dfb0-1 2f6bb597d7aa54a447f1502433e3c6733dd3c8b8
        mingw-w64-i686-git 2.41.0.3.4a1821dfb0-1 1f5ac9caac2e8e93a8b042e9f3704b80eb892107

        ************************************************************
        ```

    - A single matching release will just provide the required entries as shown below:

        ```
        PS C:\src\pacman-for-git> .\update.ps1 -Version 2.52.0

        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        New entries to be added to 'version-tags.txt'.
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        mingw-w64-x86_64-git 2.52.0.1.2912d8e9b8-1 056986d4a1d696008d6e1231f69fdaec703be91b
        mingw-w64-i686-git 2.52.0.1.2912d8e9b8-1 7c1707e4314d377242d3d3fa9a186c34f05bd0d4

        ************************************************************
        ```

2. Add the new entries shown at the bottom of the script output to `version-tags.txt`
3. Open a Pull Request to `main` to contribute.

### The Manual Way

Each release adds a new *package-versions-X.YY.Z.txt* file in the [versions](https://github.com/git-for-windows/build-extra/tree/main/versions) folder of the *build-extra* project. Open that version file and copy the line starts with "mingw-w64-x86_64-git " (a space immediately after the 't'). For example,

    mingw-w64-x86_64-git 2.39.1.1.b03dafd9c2-1

Paste that as a new line in the *version-tags.txt* file. Paste it to another new line for the 32-bit version and replace 'x65_64' with 'i686'. For example,

    mingw-w64-i686-git 2.39.1.1.b03dafd9c2-1

Click and open this [release](https://github.com/git-for-windows/git/releases) page and find that version. Hover on the release date on the left hand column (above the git-for-windows-ci icon) to get the exact date and time of the release. For example,

    Jan 17, 2023, 10:05 AM PST

Open this [64-bit SDK commit history](https://github.com/git-for-windows/git-sdk-64/commits/main) page. Find the commit ID with a date and time closest to but before the release time. Hover on the date after the word "committed" or "committed on" to get the exact date and time. For example, a commit on 'Jan 17, 2023, 7:07 PM PST' is the wrong one for the above release date. Copy the commit ID and append it with a space to the new 'x86_64' line in *version-tags.txt*.

Open this [32-bit SDK commit history](https://github.com/git-for-windows/git-sdk-32/commits/main) page. Find the commit ID with a date and time closest to but before the release time. Copy the commit ID and append it with a space to the new 'i686' line in *version-tags.txt*.
