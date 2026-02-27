#!/usr/bin/env python3
"""
Copy (or move) all Spotify Liked Songs into a playlist.

Setup:
1) Create an app at https://developer.spotify.com/dashboard.
2) Add your redirect URI in the app settings (for example: http://127.0.0.1:8080/callback).
3) Export:
   - SPOTIFY_CLIENT_ID (or SPOTIPY_CLIENT_ID)
   - SPOTIFY_REDIRECT_URI (or SPOTIPY_REDIRECT_URI)
4) Install dependency: pip install requests

Examples:
  python spotify_loved_to_playlist.py --playlist-name "Loved Songs Archive"
  python spotify_loved_to_playlist.py --playlist-name "Loved Songs Archive" --remove-from-liked
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import time
import webbrowser
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional, Sequence
from urllib.parse import parse_qs, urlencode, urlparse

import requests

SPOTIFY_AUTH_URL = "https://accounts.spotify.com/authorize"
SPOTIFY_TOKEN_URL = "https://accounts.spotify.com/api/token"
SPOTIFY_API_BASE = "https://api.spotify.com/v1"

SCOPES = " ".join(
    [
        "user-library-read",
        "user-library-modify",
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-public",
        "playlist-modify-private",
    ]
)


@dataclass(frozen=True)
class SavedTrack:
    track_id: str
    uri: str


def chunked(items: Sequence[str], size: int) -> Iterable[List[str]]:
    for index in range(0, len(items), size):
        yield list(items[index : index + size])


def build_code_verifier() -> str:
    return secrets.token_urlsafe(72)[:128]


def build_code_challenge(code_verifier: str) -> str:
    digest = hashlib.sha256(code_verifier.encode("utf-8")).digest()
    return base64.urlsafe_b64encode(digest).decode("utf-8").rstrip("=")


def parse_auth_code(callback_value: str) -> Optional[str]:
    callback_value = callback_value.strip()
    if not callback_value:
        return None

    if callback_value.startswith("http://") or callback_value.startswith("https://"):
        parsed = urlparse(callback_value)
        return parse_qs(parsed.query).get("code", [None])[0]

    return callback_value


class SpotifyClient:
    def __init__(self, client_id: str, redirect_uri: str, cache_file: Path) -> None:
        self.client_id = client_id
        self.redirect_uri = redirect_uri
        self.cache_file = cache_file
        self.session = requests.Session()
        self.token = self._load_cached_token()

    def _load_cached_token(self) -> Optional[dict]:
        if not self.cache_file.exists():
            return None
        try:
            with self.cache_file.open("r", encoding="utf-8") as handle:
                data = json.load(handle)
            if not isinstance(data, dict):
                return None
            return data
        except (OSError, json.JSONDecodeError):
            return None

    def _save_token(self, payload: dict) -> None:
        self.cache_file.parent.mkdir(parents=True, exist_ok=True)
        with self.cache_file.open("w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2)

    def _token_is_valid(self) -> bool:
        if not self.token:
            return False
        expires_at = self.token.get("expires_at", 0)
        access_token = self.token.get("access_token")
        if not access_token:
            return False
        return time.time() < float(expires_at) - 60

    def _authorize_interactively(self) -> None:
        code_verifier = build_code_verifier()
        code_challenge = build_code_challenge(code_verifier)

        params = {
            "client_id": self.client_id,
            "response_type": "code",
            "redirect_uri": self.redirect_uri,
            "scope": SCOPES,
            "code_challenge_method": "S256",
            "code_challenge": code_challenge,
        }

        auth_url = f"{SPOTIFY_AUTH_URL}?{urlencode(params)}"
        print("Open this URL to authorize the script:")
        print(auth_url)
        webbrowser.open(auth_url, new=1)

        callback_value = input(
            "\nPaste the full redirect URL (or just the `code` query parameter):\n> "
        )
        code = parse_auth_code(callback_value)
        if not code:
            raise RuntimeError("Could not find an authorization code.")

        token_response = requests.post(
            SPOTIFY_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "client_id": self.client_id,
                "code": code,
                "redirect_uri": self.redirect_uri,
                "code_verifier": code_verifier,
            },
            timeout=30,
        )
        if token_response.status_code != 200:
            raise RuntimeError(
                f"Token exchange failed ({token_response.status_code}): {token_response.text}"
            )

        payload = token_response.json()
        self.token = {
            "access_token": payload["access_token"],
            "refresh_token": payload.get("refresh_token"),
            "expires_at": time.time() + int(payload.get("expires_in", 3600)),
        }
        self._save_token(self.token)

    def _refresh_access_token(self) -> bool:
        if not self.token:
            return False
        refresh_token = self.token.get("refresh_token")
        if not refresh_token:
            return False

        response = requests.post(
            SPOTIFY_TOKEN_URL,
            data={
                "grant_type": "refresh_token",
                "refresh_token": refresh_token,
                "client_id": self.client_id,
            },
            timeout=30,
        )
        if response.status_code != 200:
            return False

        payload = response.json()
        self.token["access_token"] = payload["access_token"]
        self.token["expires_at"] = time.time() + int(payload.get("expires_in", 3600))
        if payload.get("refresh_token"):
            self.token["refresh_token"] = payload["refresh_token"]
        self._save_token(self.token)
        return True

    def _ensure_access_token(self) -> None:
        if self._token_is_valid():
            return
        if self._refresh_access_token() and self._token_is_valid():
            return
        self._authorize_interactively()

    def request(
        self,
        method: str,
        path: str,
        params: Optional[dict] = None,
        json_body: Optional[dict] = None,
        retry_auth: bool = True,
    ) -> dict:
        self._ensure_access_token()

        url = f"{SPOTIFY_API_BASE}{path}"
        headers = {"Authorization": f"Bearer {self.token['access_token']}"}

        response = self.session.request(
            method,
            url,
            params=params,
            json=json_body,
            headers=headers,
            timeout=30,
        )

        if response.status_code == 429:
            retry_after = int(response.headers.get("Retry-After", "1"))
            time.sleep(retry_after + 1)
            return self.request(method, path, params=params, json_body=json_body, retry_auth=retry_auth)

        if response.status_code == 401 and retry_auth:
            refreshed = self._refresh_access_token()
            if not refreshed:
                self._authorize_interactively()
                refreshed = self._token_is_valid()
            if refreshed:
                return self.request(method, path, params=params, json_body=json_body, retry_auth=False)

        if response.status_code >= 400:
            raise RuntimeError(f"Spotify API error {response.status_code}: {response.text}")

        if response.status_code == 204 or not response.text:
            return {}

        return response.json()


def fetch_current_user_id(client: SpotifyClient) -> str:
    profile = client.request("GET", "/me")
    user_id = profile.get("id")
    if not user_id:
        raise RuntimeError("Could not read current Spotify user id.")
    return user_id


def fetch_all_saved_tracks(client: SpotifyClient) -> List[SavedTrack]:
    tracks: List[SavedTrack] = []
    offset = 0

    while True:
        page = client.request("GET", "/me/tracks", params={"limit": 50, "offset": offset})
        items = page.get("items", [])

        for item in items:
            track = item.get("track") or {}
            track_id = track.get("id")
            uri = track.get("uri")
            if track_id and uri:
                tracks.append(SavedTrack(track_id=track_id, uri=uri))

        print(f"Fetched {len(tracks)} liked songs...", end="\r", flush=True)

        if not page.get("next") or not items:
            break
        offset += len(items)

    print(" " * 80, end="\r")
    return tracks


def dedupe_tracks(tracks: List[SavedTrack]) -> List[SavedTrack]:
    seen_ids = set()
    unique_tracks: List[SavedTrack] = []
    for track in tracks:
        if track.track_id in seen_ids:
            continue
        seen_ids.add(track.track_id)
        unique_tracks.append(track)
    return unique_tracks


def find_or_create_playlist(
    client: SpotifyClient,
    user_id: str,
    name: str,
    description: str,
    is_public: bool,
) -> tuple[str, bool]:
    offset = 0
    while True:
        page = client.request("GET", "/me/playlists", params={"limit": 50, "offset": offset})
        items = page.get("items", [])
        for playlist in items:
            if playlist.get("name") == name and (playlist.get("owner") or {}).get("id") == user_id:
                playlist_id = playlist.get("id")
                if playlist_id:
                    return playlist_id, False

        if not page.get("next") or not items:
            break
        offset += len(items)

    created = client.request(
        "POST",
        f"/users/{user_id}/playlists",
        json_body={"name": name, "description": description, "public": is_public},
    )
    playlist_id = created.get("id")
    if not playlist_id:
        raise RuntimeError("Playlist creation succeeded but no playlist id was returned.")
    return playlist_id, True


def fetch_playlist_track_ids(client: SpotifyClient, playlist_id: str) -> set[str]:
    ids: set[str] = set()
    offset = 0

    while True:
        page = client.request(
            "GET",
            f"/playlists/{playlist_id}/tracks",
            params={"limit": 100, "offset": offset, "fields": "items(track(id)),next"},
        )
        items = page.get("items", [])

        for item in items:
            track = item.get("track") or {}
            track_id = track.get("id")
            if track_id:
                ids.add(track_id)

        if not page.get("next") or not items:
            break
        offset += len(items)

    return ids


def add_tracks_to_playlist(client: SpotifyClient, playlist_id: str, uris: List[str]) -> int:
    if not uris:
        return 0

    total_chunks = (len(uris) + 99) // 100
    added = 0

    for chunk_index, uri_chunk in enumerate(chunked(uris, 100), start=1):
        client.request("POST", f"/playlists/{playlist_id}/tracks", json_body={"uris": uri_chunk})
        added += len(uri_chunk)
        print(f"Added {added}/{len(uris)} tracks ({chunk_index}/{total_chunks} requests)")

    return added


def remove_tracks_from_liked(client: SpotifyClient, track_ids: List[str]) -> int:
    if not track_ids:
        return 0

    total_chunks = (len(track_ids) + 49) // 50
    removed = 0

    for chunk_index, id_chunk in enumerate(chunked(track_ids, 50), start=1):
        client.request("DELETE", "/me/tracks", json_body={"ids": id_chunk})
        removed += len(id_chunk)
        print(f"Removed {removed}/{len(track_ids)} liked tracks ({chunk_index}/{total_chunks} requests)")

    return removed


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Collect all Spotify liked songs and sync them into a playlist."
    )
    parser.add_argument("--playlist-name", default="Loved Songs", help="Target playlist name")
    parser.add_argument(
        "--description",
        default="Auto-synced from Spotify Liked Songs.",
        help="Playlist description (used only when creating a new playlist)",
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="Create playlist as public (default: private)",
    )
    parser.add_argument(
        "--remove-from-liked",
        action="store_true",
        help="After syncing to playlist, remove those tracks from Liked Songs (true move).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Skip confirmation prompt when --remove-from-liked is used.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would happen without modifying playlists or liked songs.",
    )
    parser.add_argument(
        "--cache-file",
        default=".spotify_loved_token.json",
        help="Path to OAuth token cache file.",
    )
    return parser.parse_args()


def get_required_env(name_options: Sequence[str]) -> Optional[str]:
    for option in name_options:
        value = os.getenv(option)
        if value:
            return value
    return None


def main() -> int:
    args = parse_args()

    client_id = get_required_env(("SPOTIFY_CLIENT_ID", "SPOTIPY_CLIENT_ID"))
    redirect_uri = get_required_env(("SPOTIFY_REDIRECT_URI", "SPOTIPY_REDIRECT_URI"))

    if not client_id or not redirect_uri:
        print("Missing required environment variables.", file=sys.stderr)
        print("Set SPOTIFY_CLIENT_ID and SPOTIFY_REDIRECT_URI.", file=sys.stderr)
        return 1

    client = SpotifyClient(
        client_id=client_id,
        redirect_uri=redirect_uri,
        cache_file=Path(args.cache_file).expanduser(),
    )

    try:
        user_id = fetch_current_user_id(client)
        saved_tracks = dedupe_tracks(fetch_all_saved_tracks(client))

        if not saved_tracks:
            print("No liked songs found in your Spotify library.")
            return 0

        playlist_id, was_created = find_or_create_playlist(
            client=client,
            user_id=user_id,
            name=args.playlist_name,
            description=args.description,
            is_public=args.public,
        )

        existing_ids = fetch_playlist_track_ids(client, playlist_id)
        uris_to_add = [track.uri for track in saved_tracks if track.track_id not in existing_ids]

        print(f"Liked songs found: {len(saved_tracks)}")
        print(f"Already in playlist: {len(saved_tracks) - len(uris_to_add)}")
        print(f"Need to add: {len(uris_to_add)}")
        print(f"Playlist: {args.playlist_name} ({'created' if was_created else 'existing'})")

        if args.dry_run:
            print("Dry run complete. No changes were made.")
            return 0

        add_tracks_to_playlist(client, playlist_id, uris_to_add)

        if args.remove_from_liked:
            if not args.yes:
                confirmation = input(
                    "\nThis will remove synced tracks from your Liked Songs. Continue? [y/N]: "
                ).strip().lower()
                if confirmation not in {"y", "yes"}:
                    print("Skipped removal from Liked Songs.")
                    return 0

            track_ids_to_remove = [track.track_id for track in saved_tracks]
            remove_tracks_from_liked(client, track_ids_to_remove)

        print("Done.")
        return 0

    except KeyboardInterrupt:
        print("\nInterrupted by user.")
        return 130
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
