# dist-transcode

Watch a video directory and farm out transcoding jobs across LAN worker hosts over SSH — no agents, no message queues, zero infrastructure beyond existing SSH keys.

## Requirements

| Host    | Needs                         |
|---------|-------------------------------|
| Source  | `bash`, `ssh/scp`, `inotify-tools` |
| Workers | `transcode-video.rb` on `$PATH`    |

## Quick start

1. Create `workers.txt` — one SSH-accessible host per line (comments & blanks ignored):
```text
austin@rainbowroad.local
austin@redalert.local
```

2. Run:
```bash
# Watch ~/videos, output to ~/output, default workers
./watch_transcode.sh

# Custom paths + worker file
./watch_transcode.sh /mnt/media/videos /mnt/storage/av1 /etc/my_workers.txt
```

## How it works

1. `inotifywait` watches the input dir for new/complete video files (`.mkv`, `.mp4`, `.avi`, `.mov`, `.webm`, `.m4v`)
2. Each batch is dispatched to free workers in round-robin fashion
3. Per job: SCP file → worker → run `transcode-video.rb -m av1` → SCP result back → cleanup temp files
4. Subfolder structure from input is preserved identically in output

Files matching `*_av1*` are automatically skipped. Naming convention: `movie.mp4` → `movie_av1.mp4`.
