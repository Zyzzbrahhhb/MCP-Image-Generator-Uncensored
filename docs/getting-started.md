# Getting started

Each step of the first start, each choice, and what to do when something goes wrong. The examples show the
Windows scripts. On Linux, run the `.sh` scripts in a terminal (`./start.sh` instead of `start.cmd`). The
screens are almost the same.

## Before you start

| You need | Details |
|---|---|
| Docker | **Windows**: [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) (WSL 2). **Linux**: [Docker Engine](https://docs.docker.com/engine/install/) with Compose, `curl`, and the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) for a GPU. |
| GPU (optional) | NVIDIA GTX 16xx / RTX 20xx or newer, 4 GB or more (12 GB recommended), driver 570 or newer. Without a GPU, the server uses the CPU: several minutes per image. |
| Memory | Docker needs 12 GB or more (16 GB on the CPU). On Windows, Docker gets half of the RAM, so 32 GB of RAM is recommended. |
| Disk | 12-16 GB for the models, 6 GB for the server, and space for the first build. |

1. Install [Git](https://git-scm.com/downloads).
2. Open a terminal and run:

   ```bash
   git clone https://github.com/hypersniper05/MCP-Image-Generator-Uncensored.git
   ```

3. Open the new folder `MCP-Image-Generator-Uncensored`. The scripts are in this folder.

Without Git, download the ZIP file (**Code > Download ZIP** on GitHub) and extract it. A ZIP copy cannot update
itself.

## The four scripts

| Windows | Linux | What it does |
|---|---|---|
| `start.cmd` | `./start.sh` | Starts the server. If the first install did not finish, it runs the setup first. |
| `setup.cmd` | `./setup.sh` | Asks where the server runs and which model to use, then starts it. Your current settings are the defaults. |
| `update.cmd` | `./update.sh` | Installs the latest version. Settings, models and images stay. |
| `stop.cmd` | `./stop.sh` | Stops the server. |

Double-click a `.cmd` file. The window stays open at the end so that you can read the result.

**Answers**: the value in square brackets is the default. Press Enter to use it, or type a number. In a yes/no
question, the capital letter is the default: `[Y/n]` means Enter is yes, `[y/N]` means Enter is no.

## The first start

Double-click `start.cmd`. It does four steps.

### Step 1: Docker

```
Image Gen MCP
==> Checking Docker...
    Docker is running.
```

If Docker is missing or stopped, the script says what to do and stops. See [Messages](#messages).

### Step 2: Where the server runs

One GPU: the script shows it and continues.

```
    Memory Docker can use: 24 GB
    GPU: NVIDIA GeForce RTX 3080 Ti, 12 GB (Turbo)
```

Several GPUs: choose one.

```
    GPUs found:
      0) NVIDIA GeForce RTX 5090, 32 GB      any model, all on the GPU  <- recommended
      1) NVIDIA GeForce RTX 3080, 10 GB      Turbo
      2) NVIDIA GeForce RTX 3080 Ti, 12 GB   Turbo
      3) Custom load (multi-GPU and CPU)

Which GPU should the image server use?
Type a number and press Enter [0]:
```

- Next to each GPU: `Turbo`, or `any model, all on the GPU` when even Best quality fits (20 GB or more). The
  script recommends the GPU with the most memory.
- Choose a GPU that no other program uses. The whole model goes on it. If it does not all fit, the server keeps
  some weights in RAM by itself. With 8 GB or more the speed stays about the same. With 4-7 GB each image takes
  about 2 times longer.
- The last choice lets you place each part of the model yourself. See [Custom load](#custom-load).
- A GPU with 4-7 GB runs Turbo with most of the model in RAM. Docker then needs about 12 GB of memory.
- A GPU with less than 4 GB is too small. The script asks again. If it is your only GPU, the script offers the
  CPU.
- Without an NVIDIA GPU, the script asks `Continue on the CPU (several minutes per image)? [Y/n]`. If you have an
  NVIDIA GPU, type `n`, install its driver, and run `start.cmd` again.

If Docker can use less than 12 GB (16 GB on the CPU), the script warns you. See [Give Docker more memory](#give-docker-more-memory).

### Step 3: The model

```
Which model do you want to use? (on GPU 2: NVIDIA GeForce RTX 3080 Ti, 12 GB)

    Choice          Download     GPU memory   Time per image
 1) Best quality    13.3 GB      18 GB        ~90 s
 2) Standard        4.6 GB       14 GB        ~90 s
 3) Turbo           downloaded   14 GB        ~11 s  <- current, recommended
```

| Choice | What you get |
|---|---|
| Best quality | Non-Turbo model, large text encoder. Best text and prompt following. |
| Standard | Non-Turbo model, small text encoder. Needs less memory. |
| Turbo | Official Turbo model. About 8 times faster. Weaker at small text. |

- **Download**: what is still missing. The models share files, so a second model downloads less.
- **GPU memory**: the whole model on the GPU. A smaller GPU keeps some weights in RAM: about the same speed on
  8 GB or more, slower with less.
- **Time per image**: 1024x1024 on an RTX 3080 Ti. An RTX 5090 is about 2 times faster. An older GPU is much
  slower: Turbo on a GTX 1650 takes about 10 minutes.
- `<- recommended` marks Turbo, the fastest choice. `<- current` is the model that you use now.
- Best quality with less than 20 GB for Docker: the script asks `Use it anyway? [y/N]`. Type `y` to keep it.
- A model set by hand in `config.yaml` shows as `Keep the current model`. It is the default.

If the GPU is small for the whole model, the script tells you after your choice:

```
    This GPU is small for the whole model: the server keeps part of it in RAM, so each image takes longer.
```

### Custom load

Only after `Custom load (multi-GPU and CPU)`. The model has three parts. You choose where each part runs.

![The image model on GPU 0, the text encoder on GPU 1 and the image decoder on the CPU, all connected to the server, which makes the image](images/split-diagram.webp)

| Part | What it does | Put it on |
|---|---|---|
| Image model | Makes the image. Most of the work. | The fastest GPU, or several GPUs. |
| Text encoder | Reads the prompt and the input images. | **RAM** (recommended for a GPU with 12-19 GB): the weights stay in RAM and the text encoder runs on the image model's GPU. Its weights (5.0 GB, or 8.7 GB with Q8_0) then stay out of GPU memory. That GPU needs 8 GB or more. On 8-11 GB, RAM was slower than the GPU (19 s against 12 s at 1344x768). You can also choose a GPU or the CPU. On the CPU, edits take much longer. |
| Image decoder | Turns the result into pixels. The upscaler also runs here. | A GPU. On the CPU, each image and each upscale takes longer. |

The script asks for each part, then shows your choice:

```
Your custom load:
    Image model (4.6 GB):    GPU 0 (NVIDIA GeForce RTX 5090, 32 GB) + GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)
    Text encoder (5.0 GB):   GPU 0 (NVIDIA GeForce RTX 5090, 32 GB)
    Image decoder (0.7 GB):  GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)

  1) Confirm
  2) Start over
```

If a GPU may not have enough memory for its parts, the script warns you before `1) Confirm`:

```
    GPU 1 (NVIDIA GeForce RTX 3080, 10 GB) may run out of memory: its parts need about 9 GB.
    The server then works more slowly (it moves parts to RAM) or stops with an out-of-memory error.
```

### The saved settings

```
==> Saved in config.yaml: Best quality (uncensored Q4_K_M, text encoder Q8_0)
    and the GPU settings: GPU 2 (limited to 10 GB), text encoder in RAM.
```

- **Limited to 10 GB**: on a GPU with less than 20 GB, the server plans for 2 GB less than the GPU has. The rest is
  for the screen and other programs. A GPU with 9-11 GB that runs every part of the model gets 6 GB. The server then
  keeps the weights in RAM, and the image decoder has room. In a fast PCIe slot, Turbo on a 10 GB GPU took about
  12 s at 1344x768 with 6 GB, against about 19 s with 8 GB.
- **Text encoder in RAM**: only when you chose it in the custom load.

The setup changes only the device, the GPU settings, the model and `generation.prefix_cache_type`. Your other
settings in `config.yaml` stay.

### Optional extensions

Then the setup offers the extensions in the `extensions` folder. Now there is one, the Kandinsky 6 video
extension (see [Kandinsky 6 video](kandinsky6.md)). Enter keeps your current answer; the default is no.

```
Optional extension: Kandinsky 6 Lite video (4-bit)
    Makes 5-20 second videos with sound from a text description or from an image (generate_video), continues
    videos (extend_video), and makes transparent animations and GIFs. Needs an NVIDIA GPU with 8 GB or more and
    about 16 GB more Docker memory; downloads about 13 GB once. About 1-3 minutes per 5 seconds of video on a
    consumer GPU.

Install this extension? [y/N]
```

With more than one GPU, it asks which GPU the video uses. The default is the largest GPU that the image model does
not use. Then it shows its choice:

```
==> Video: GPU 2 (12 GB), mode stream.
    It shares this GPU with the image model: one job runs at a time (a video waits for an image and the
    other way round), and the image model is limited to 6 GB. About 2.5 minutes per 5 s of video.
```

- **Mode**: how the video model uses the GPU, set from its memory: `resident` (20 GB or more), `fast`,
  `low-memory` (10-13 GB) or `stream` (8-9 GB, or a GPU of 12 GB or less that the image model also uses).
- To remove the extension, run the setup again and answer `n`. The setup removes its container and its Docker
  image, and asks before it deletes the downloaded files (about 13 GB).

### Step 4: Build, download, start

```
==> Building the image server (first time only, 10-30 minutes)
==> Starting the server...
==> Downloading the model files (first time only, or after changing the model): 15.37 GB
    6.15 of 15.37 GB (40%)
==> Loading the model on GPU 2 (NVIDIA GeForce RTX 3080 Ti, 12 GB)...

Ready. Add this address to your AI app as an MCP server:
    http://localhost:5005/mcp
Status page: http://localhost:5005 (open it in a browser)
```

- If the build or the download stops, run `start.cmd` again. Both continue where they stopped.
- With the video extension, the start then builds it, downloads its models (first time only, about 13 GB) and
  starts it:

  ```
  ==> Extension: Kandinsky 6 Lite video (4-bit)
      Building its image (the first time takes several minutes)...
      Downloading its models once (about 13 GB) and checking them...
      Ready. Its tools are offered on the server's MCP address within a few seconds.
  ```
- Loading can take several minutes on the first start, or on a GPU with little memory. After one minute, the
  script shows `still loading: 1 min`, `2 min` and so on. On a GTX 1650 (4 GB), with the models already downloaded, the first start took 6.4 minutes: 2.6 minutes to
  check the model files on a hard disk, then 3.8 minutes to load.
- Add the address to your AI app (your MCP client). See [Connect an MCP client](../README.md#connect-an-mcp-client).
- The server runs in Docker, not in the window. You can close the window. Docker starts the server again after
  a restart of the computer, until you run `stop.cmd`.

## Make a video

With the video extension installed, ask your AI app for a video, as you ask for an image. The tools are on the same
MCP address. A 5-second video takes about 1-3 minutes on a consumer GPU (40-60 s on an RTX 5090). Your AI app gets
a job id at once and asks the server again until the video is ready. Then it shows a link and a poster image. The
[web gallery](http://localhost:5005) plays every video.

| You want | Ask your AI app | What it does |
|---|---|---|
| A video from a description | "Make a 5-second video of a snowy cabin at night, the camera slowly pushes in" | `generate_video` |
| A picture brought to life | "Animate this photo: the waves crash on the rocks" (with the image) | `generate_video` with `image`: the picture is the first frame |
| A transparent animation | "Make a transparent image of a cartoon dragon, then animate it flapping its wings" | `generate_image` with `transparent: true`, then `generate_video` with that image and `transparent: true` |
| A GIF | "Make it a GIF" | `gif: true`, or `video_to_gif` on a video you have |
| Several versions | "Make 3 versions" | `count: 3`: each version has the next seed |
| A longer video | "Make it 15 seconds: first it walks, then it digs, then it jumps" | `seconds: 15` and `next_prompts`, or `extend_video` on a finished video |

- **Write explicit prompts.** The model does what the prompt says and does not work out the rest. Say where things
  are, which way each thing moves, what the camera does and what stays still. See
  [How to prompt](kandinsky6.md#how-to-prompt).
- **Keep the motion calm.** The model does best with motion that needs no physics: idle loops, steam, flames,
  blinking, slow camera moves. Fast action often goes wrong.
- **Transparent animations** start from an image with a transparent background, and the motion stays in place. The
  result is a WebM with transparency and an animated WebP. See [Transparent videos](kandinsky6.md#transparent-videos).
- **One GPU for images and video**: on a GPU of 12 GB or less, a video waits for an image job and the other way round.

## Later

| To | Run | What happens |
|---|---|---|
| Start the server | `start.cmd` | If it already runs, the script asks `Restart it? [y/N]`. It restarts without a question after an update that changed the server, or after an error. |
| Change the model or the GPU | `setup.cmd` | The same questions. Enter keeps each current setting. A new model downloads. The build is kept. |
| Update | `update.cmd` | Lists the updates and installs them. If the server changed, it asks `Do that now? [Y/n]` to build and restart. |
| Stop | `stop.cmd` | Stops the server. |

**Update with changed files**: if you changed a project file that the update also changes, the script asks:

```
  1) Cancel the update and keep the changes
  2) Discard the changes and install the update
```

With 2, git keeps a copy of your changes (`git stash list`) and of the old version (branch `before-update-...`).

**Old model files**: they stay in `models`. Delete them to free disk space. If you delete a file that the current
model uses, it downloads again.

## Messages

| Message | What to do |
|---|---|
| Docker is not installed. | Install Docker. Run the script again. |
| Docker is installed but not running. | **Windows**: start Docker Desktop and wait for "Engine running". **Linux**: `sudo systemctl start docker`. Run the script again. |
| Docker Desktop is running, but your Windows user may not use it yet. | Sign out of Windows and sign in again. |
| Docker is running, but your user may not use it. | **Linux**: `sudo usermod -aG docker $USER`. Log out and log in again. |
| Port 5005 is used by another program. | Close that program, or change `port` under `server:` in `config.yaml`. |
| Docker cannot reach the NVIDIA GPU. | **Windows**: update the NVIDIA driver (570+), restart the computer. **Linux**: install the NVIDIA Container Toolkit, restart Docker. |
| The build failed. | Check the internet and the free disk space. Out of memory: set `BUILD_JOBS=4` in `.env`. |
| The model does not fit in memory. | Run `setup.cmd` and choose a smaller model. |
| The model download failed. | Check the internet. Run `start.cmd` again. |
| The server stopped while starting. | The script shows the end of the server log with the cause. Correct `config.yaml` or run `setup.cmd`. |
| Images fail with "lost the connection to the inference engine". | The engine stopped, usually because it ran out of memory. Give Docker more memory, or choose a smaller model. |

Full log: open a terminal in the project folder and run `docker compose logs --tail 80`.

### Give Docker more memory

- **Windows**: open Notepad and type:

  ```
  [wsl2]
  memory=24GB
  ```

  Use about 8 GB less than your RAM (24GB for 32 GB of RAM). Select **File > Save as**, set **Save as type** to
  **All files**, and save as `%UserProfile%\.wslconfig`. If the file exists, add only the `memory=` line under
  `[wsl2]`. With 16 GB of RAM, use `memory=12GB` and close other programs (tested with a GTX 1650). Then run
  `wsl --shutdown` and start Docker Desktop again. If Docker Desktop does not start, restart the computer.
- **Linux**: Docker can use all of the RAM. Close other programs.

## Where your files are

| File or folder | What it holds |
|---|---|
| `config.yaml` | Your settings. [`config.example.yaml`](../config.example.yaml) explains each one. |
| `.env` | Docker settings, for example the build options. The port comes from `config.yaml`. |
| `models` | The model files. |
| `outputs` | Your images, videos, GIFs and uploads. **The server deletes files older than 7 days.** To keep them, set `outputs.keep_days: 0` in `config.yaml`. |
| `inputs` | Images that the tools can read by file name. |
| `extensions/kandinsky6/models`, `extensions/kandinsky6/.env` | The video extension's model files (about 13 GB) and its settings for this computer (GPU, memory mode). |

Updates do not change these files.
