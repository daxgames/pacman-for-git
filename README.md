# pacman-for-git
Facilitate installing pacman in [Git for Windows](https://github.com/git-for-windows/git/releases), started from this [StackOverflow answer](https://stackoverflow.com/a/65204171).

## How to Update version-tags.txt

### The Easy Way

`get-versiontags` will show hashes for the latest released version by default.  Alternatively you can use command line arguments to get a specific version.

The script can also be run from `cmd.exe` and `bash.exe` using the included shim scripts.

See below:

1. Use `get-versiontags [-version <git-version> -latest [true|false]` as shown below:

    - To get hashes for the `latest` released version:
    
        ```
        PS C:\src\pacman-for-git> ./get-versiontags
        New entries to be added to 'version-tags.txt'.
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        mingw-w64-x86_64-git 2.52.0.1.2912d8e9b8-1 056986d4a1d696008d6e1231f69fdaec703be91b
        mingw-w64-i686-git 2.52.0.1.2912d8e9b8-1 7c1707e4314d377242d3d3fa9a186c34f05bd0d4

        ************************************************************
        ```

    - To get hashes for a specific release of a specific Major/Minor release:

        ```
        PS C:\src\pacman-for-git> ./get-versiontags -version 2.39 -latest false
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        Multiple Matching Releases Found Pick One
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        1: v2.39.2.windows.1  - 2/14/2023 6:11:17 PM
        2: v2.39.1.windows.1  - 1/17/2023 6:05:28 PM
        3: v2.39.0.windows.2  - 12/21/2022 2:44:06 PM
        4: v2.39.0.windows.1  - 12/12/2022 4:59:50 PM

        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=
        Enter number of release to use (1..4) [default: 1, q to quit]: 3
        New entries to be added to 'version-tags.txt'.
        =-=-=--=-=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=--=-=-=-=-=

        mingw-w64-x86_64-git 2.39.0.2.e7d4c50480-1 f76ce435567b3a2b6d02cedcb8a66df71e2aae89
        mingw-w64-i686-git 2.39.0.2.e7d4c50480-1 3bce40e4f13b0ef12c634009d8ad500389c6bfe0

        ************************************************************
        ```

    - A single matching release will just provide the required entries as shown below:

        ```
        PS C:\src\pacman-for-git> .\get-versiontags -Version 2.52.0

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
