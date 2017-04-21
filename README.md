# vk-albums
vk.com albums downloader.

This perl-script downloads all photo-albums of given group.
You don't need to be logged in to site.

## Usage

```
vk_albums.pl <url>
```
Parameter `<url>` is an url of "Photo Albums" page, it's format is `https://vk.com/albums-<club_id>`.
Script creates dir `albums-<club_id>` in current dir.
In this dir for every album it creates dir named `<number> album-<club_id>_<album_id> <album_name>` and
downloads all photos named `<number> photo-<club_id>_<photo_id>.jpg` to this dir.

Script prints log to STDOUT.
