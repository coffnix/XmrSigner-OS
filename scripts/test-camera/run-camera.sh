rpicam-vid --timeout 0 --codec yuv420 --width 640 --height 480 -o - \
| ffmpeg -hide_banner -loglevel error \
    -f rawvideo -pix_fmt yuv420p -video_size 640x480 -i - \
    -vf scale=296:300,format=bgra \
    -f rawvideo -pix_fmt bgra - \
| python3 /root/fb_sink.py --input bgra --width 296 --height 300
