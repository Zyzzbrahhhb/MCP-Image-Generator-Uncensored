"""The built-in web page: a gallery of every image on the server (folders, filters, search, sort, multi-select,
trash, a viewer with each image's settings), uploads by drag and drop, and the server status."""
from urllib.parse import quote

LOGO = """<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="181 182 661 660"><g stroke-width="0.8" stroke-linejoin="round"><path d="M0 0 C-0.62 4.56 -2.47 8.28 -4.56 12.31 C-5.3 13.76 -6.04 15.21 -6.77 16.66 C-7.15 17.39 -7.52 18.12 -7.91 18.87 C-19.02 40.56 -29.7 62.47 -39 85 C-39.2 85.48 -39.2 85.48 -40.21 87.9 C-121.23 282.61 -121.23 282.61 -93 354 C-92.24 355.62 -91.45 357.22 -90.62 358.81 C-90.36 359.34 -90.36 359.34 -89 362 C-89.33 362.66 -89.66 363.32 -90 364 C-96.57 357.52 -103.06 351.07 -109 344 C-109.43 343.5 -109.43 343.5 -111.59 340.97 C-121.23 329.67 -130.35 318.02 -139.33 306.19 C-140.41 304.77 -141.5 303.35 -142.58 301.93 C-144.1 299.93 -145.61 297.94 -147.12 295.94 C-147.55 295.37 -147.98 294.81 -148.43 294.23 C-158.12 281.37 -166.89 267.77 -175.81 254.38 C-176.33 253.59 -176.86 252.81 -177.39 252 C-189.03 234.53 -200.37 216.93 -211.09 198.87 C-213.31 195.13 -215.59 191.42 -217.88 187.71 C-222.23 180.66 -226.44 173.54 -230.64 166.39 C-234.42 159.98 -238.23 153.59 -242.18 147.28 C-242.84 146.23 -243.49 145.18 -244.16 144.1 C-245.41 142.11 -246.66 140.13 -247.92 138.16 C-248.48 137.27 -249.03 136.39 -249.6 135.47 C-250.09 134.7 -250.58 133.93 -251.08 133.14 C-252 131 -252 131 -251.76 128.9 C-250.55 125.87 -248.66 123.32 -246.75 120.69 C-246.3 120.07 -245.86 119.46 -245.4 118.82 C-232.04 100.69 -215.89 83.68 -198 70 C-196.95 69.15 -195.9 68.3 -194.86 67.45 C-140.96 23.73 -69.49 -1.38 0 0 Z " fill="#EF6B4F" stroke="#EF6B4F" transform="translate(512,202)"/><path d="M0 0 C2.86 2.69 4.95 5.28 6.92 8.68 C7.45 9.58 7.97 10.48 8.52 11.41 C9.07 12.37 9.62 13.33 10.19 14.31 C11.36 16.32 12.53 18.32 13.7 20.32 C14.26 21.3 14.83 22.27 15.42 23.28 C40.02 65.53 67.59 106.74 99.4 143.93 C101.74 146.68 104 149.49 106.25 152.31 C110.74 157.84 115.6 163.01 120.51 168.17 C123.56 171.37 126.55 174.6 129.43 177.95 C133.25 182.35 137.31 186.46 141.44 190.56 C142.15 191.28 142.86 191.99 143.6 192.73 C147.67 196.8 151.84 200.68 156.2 204.43 C158.62 206.54 160.93 208.78 163.25 211 C171.56 218.75 180.8 225.36 190 232 C190.66 232.48 191.32 232.96 192 233.45 C209 245.69 229.25 257.43 250.21 260.54 C250.5 260.62 250.5 260.62 252 261 C252.33 261.66 252.66 262.32 253 263 C186.25 278.95 116.09 283.36 47.99 290.37 C46.88 290.48 45.77 290.6 44.62 290.72 C39.39 291.26 34.16 291.79 28.93 292.33 C27.05 292.52 25.16 292.71 23.28 292.91 C22.84 292.95 22.84 292.95 20.58 293.18 C13.84 293.89 7.13 294.72 0.41 295.64 C-3.08 296.01 -6.49 296.06 -10 296 C-25.48 265.31 -36.46 232.13 -41 198 C-41.18 196.73 -41.35 195.46 -41.53 194.15 C-43.17 181.56 -43.36 169.06 -43.31 156.38 C-43.31 155.31 -43.31 154.25 -43.31 153.16 C-43.26 137.89 -42.9 123.03 -40 108 C-39.79 106.84 -39.57 105.68 -39.35 104.49 C-36.71 90.37 -33.69 76.58 -29 63 C-28.58 61.64 -28.16 60.28 -27.74 58.92 C-13.74 13.74 -13.74 13.74 0 0 Z " fill="#07A1A9" stroke="#07A1A9" transform="translate(244,356)"/><path d="M0 0 C3.57 1.48 5.5 3.45 8 6.38 C11.52 10.4 15.18 14.2 19 17.94 C23.58 22.45 27.74 27.15 31.75 32.19 C33.71 34.63 35.73 37.01 37.78 39.38 C49.42 52.85 59.77 67.44 70 82 C70.52 82.74 71.05 83.48 71.59 84.24 C75.91 90.36 80.05 96.59 84.12 102.88 C85.45 104.91 86.77 106.95 88.1 108.99 C88.75 110 89.41 111.02 90.09 112.06 C91.84 114.75 93.6 117.45 95.37 120.13 C101.7 129.78 107.8 139.54 113.76 149.42 C117.62 155.8 121.6 162.08 125.69 168.31 C130.59 175.79 135.32 183.34 139.95 190.98 C142.34 194.93 144.77 198.85 147.21 202.77 C148.31 204.55 149.42 206.33 150.53 208.11 C151.25 209.28 151.98 210.45 152.72 211.62 C153.75 213.26 154.77 214.91 155.79 216.55 C156.38 217.51 156.98 218.46 157.59 219.44 C158.85 221.73 159.75 223.41 160 226 C158.53 228.34 157.07 230.33 155.31 232.44 C154.82 233.05 154.32 233.66 153.81 234.29 C149.33 239.76 144.57 244.95 139.72 250.1 C137.5 252.46 135.36 254.85 133.25 257.31 C127.35 264.11 120.84 270.16 114 276 C113.1 276.79 112.2 277.58 111.27 278.39 C67.34 316.64 13.07 341.66 -44.38 350.75 C-45.05 350.86 -45.72 350.96 -46.41 351.07 C-58.36 352.96 -70.27 354.18 -82.38 354.06 C-83.64 354.05 -84.91 354.04 -86.21 354.04 C-86.67 354.03 -86.67 354.03 -89 354 C-87.24 347.9 -84.35 342.37 -81.56 336.69 C-75.92 325.05 -70.63 313.28 -65.49 301.41 C-63.91 297.79 -62.3 294.18 -60.69 290.58 C-41.47 247.46 -25.8 203.12 -12 158 C-11.79 157.31 -11.58 156.63 -11.36 155.92 C18.87 57.53 18.87 57.53 3 9 C2.67 7.99 2.35 6.97 2.01 5.93 C1.36 3.95 0.68 1.97 0 0 Z " fill="#07A1A9" stroke="#07A1A9" transform="translate(603,468)"/><path d="M0 0 C0.66 0.33 1.32 0.66 2 1 C-8.14 34.6 -22.77 66.97 -37 99 C-37.33 99.74 -37.66 100.48 -38 101.24 C-48.07 123.91 -58.4 146.44 -69.03 168.85 C-72.04 175.18 -75.02 181.53 -78 187.88 C-78.99 189.98 -79.98 192.08 -80.97 194.18 C-84.11 200.86 -87.25 207.54 -90.38 214.22 C-91.88 217.4 -93.37 220.58 -94.86 223.76 C-95.57 225.29 -96.29 226.81 -97 228.34 C-97.99 230.45 -98.98 232.55 -99.96 234.66 C-100.26 235.29 -100.55 235.92 -100.86 236.57 C-102.89 240.89 -102.89 240.89 -104 242 C-110.57 242.46 -117.07 241.82 -123.56 240.88 C-124.45 240.75 -125.35 240.62 -126.26 240.48 C-137.67 238.71 -148.85 235.95 -160 233 C-160.88 232.77 -161.75 232.54 -162.65 232.3 C-194.33 223.78 -224.87 209.38 -252 191 C-252.96 190.36 -253.93 189.71 -254.92 189.05 C-257.32 187.41 -259.67 185.73 -262 184 C-262.98 183.28 -263.95 182.56 -264.96 181.81 C-273.03 175.75 -280.67 169.23 -288.23 162.54 C-289.47 161.46 -290.73 160.4 -292 159.35 C-292.32 159.08 -292.32 159.08 -293.95 157.73 C-294.53 157.26 -295.12 156.78 -295.72 156.29 C-297 155 -297 155 -297 153 C-297.58 152.76 -298.15 152.52 -298.75 152.27 C-301.44 150.75 -302.98 149.02 -305 146.69 C-307.6 143.72 -310.19 140.77 -312.9 137.91 C-319.79 130.62 -326.08 123.09 -332 115 C-332.46 114.38 -332.91 113.76 -333.39 113.12 C-334.79 111.21 -336.18 109.29 -337.56 107.38 C-337.99 106.78 -338.42 106.19 -338.87 105.58 C-340.67 103.06 -342.01 100.96 -343 98 C-334.74 96.4 -326.47 95.2 -318.13 94.12 C-316.79 93.94 -315.45 93.76 -314.11 93.59 C-311.26 93.21 -308.41 92.84 -305.57 92.46 C-244.51 84.42 -184 75.13 -124.13 60.52 C-122.22 60.05 -120.32 59.6 -118.41 59.14 C-75.26 48.73 -29.45 35.08 0 0 Z " fill="#07A1A9" stroke="#07A1A9" transform="translate(592,579)"/><path d="M0 0 C12.66 24.66 20.36 51.56 25.25 78.75 C25.33 79.17 25.33 79.17 25.71 81.29 C28.45 97.63 29.38 114.01 29.31 130.56 C29.31 131.02 29.31 131.02 29.31 133.32 C29.21 158.53 26.04 182.49 20 207 C19.88 207.5 19.88 207.5 19.25 210.05 C12.32 237.46 0.63 263.32 -13 288 C-13.99 288 -14.98 288 -16 288 C-16.5 287.09 -17 286.18 -17.51 285.24 C-42.7 239.63 -72.41 194.86 -105.62 154.69 C-107.49 152.4 -109.31 150.08 -111.12 147.75 C-114.93 142.97 -119.03 138.52 -123.19 134.05 C-125.21 131.89 -127.14 129.67 -129.06 127.42 C-133.72 122.07 -138.75 117.1 -143.77 112.1 C-145.43 110.44 -147.09 108.78 -148.75 107.11 C-154.33 101.53 -159.94 96.06 -166 91 C-166.94 90.22 -167.87 89.44 -168.84 88.63 C-171.55 86.42 -174.27 84.2 -177 82 C-177.44 81.65 -177.44 81.65 -179.64 79.86 C-184.21 76.18 -188.82 72.61 -193.6 69.23 C-194.06 68.82 -194.52 68.42 -195 68 C-195 67.34 -195 66.68 -195 66 C-194.1 65.66 -193.21 65.32 -192.28 64.97 C-172.79 57.45 -154.57 47.59 -137.84 35.04 C-129.4 28.98 -120.33 23.67 -111.36 18.46 C-109 17 -109 17 -106.3 15.01 C-99.37 10.04 -99.37 10.04 -95.4 9.93 C-92.84 10.45 -90.48 11.19 -88 12 C-60.89 19.82 -30.34 11.29 -5.1 0.79 C-3 0 -3 0 0 0 Z " fill="#07A1A9" stroke="#07A1A9" transform="translate(793,381)"/><path d="M0 0 C34.81 2.23 68.05 11.26 100 25 C100.83 25.35 101.66 25.71 102.51 26.07 C122.76 34.81 142.51 46.57 160 60 C161.18 60.9 162.36 61.79 163.54 62.69 C166.71 65.1 169.86 67.54 173 70 C173.95 70.71 174.89 71.43 175.87 72.16 C176.57 72.77 177.28 73.38 178 74 C178 74.66 178 75.32 178 76 C177.67 76.18 177.67 76.18 175.98 77.07 C172.97 78.68 169.98 80.33 167 82 C166.12 82.48 165.25 82.97 164.35 83.46 C151.58 91.01 141.13 101.17 133.94 114.14 C128.47 123.62 118.24 127.62 108.88 132.56 C97.42 138.67 86.1 144.97 74.83 151.4 C71.97 153.02 69.1 154.62 66.23 156.21 C43.04 169.11 20.47 183.43 -1.09 198.91 C-1.67 199.32 -2.25 199.74 -2.85 200.17 C-4.28 201.2 -5.7 202.25 -7.12 203.3 C-14.37 207.58 -22.29 208.67 -30.5 209.88 C-60.2 214.58 -88.67 226.56 -107.06 251.5 C-107.78 252.5 -108.49 253.5 -109.22 254.53 C-111 257 -111 257 -113 259 C-111.67 250.53 -108.98 242.67 -106.06 234.62 C-105.57 233.26 -105.08 231.89 -104.59 230.52 C-96.74 208.74 -88.05 187.3 -79 166 C-78.62 165.11 -78.24 164.21 -77.85 163.29 C-70.54 146.12 -62.74 129.18 -54.94 112.23 C-53.15 108.33 -51.37 104.44 -49.59 100.54 C-44.54 89.53 -39.42 78.57 -33.91 67.78 C-32.39 64.8 -30.88 61.81 -29.38 58.81 C-29.06 58.18 -28.74 57.55 -28.42 56.91 C-25.53 51.13 -22.74 45.31 -19.95 39.5 C-13.89 26.86 -7.64 14.35 -1 2 C-0.67 1.34 -0.34 0.68 0 0 Z " fill="#EF6B4F" stroke="#EF6B4F" transform="translate(540,203)"/><path d="M0 0 C7.98 2.24 15.96 3.87 24.13 5.21 C20.35 11.74 15.52 16.94 10.13 22.21 C5.79 26.47 1.48 30.72 -2.49 35.33 C-8.97 42.83 -16.15 49 -23.87 55.21 C-25.87 56.86 -27.87 58.53 -29.87 60.21 C-29.37 60.54 -29.37 60.54 -26.87 62.21 C-37.66 71.44 -50.71 75.72 -64.8 75.46 C-75 74.61 -83.46 71.39 -90.16 63.6 C-93.05 59.55 -94.35 55.13 -95.74 50.39 C-96.04 49.45 -96.33 48.51 -96.63 47.54 C-97.17 45.81 -97.7 44.08 -98.22 42.35 C-98.74 40.62 -99.3 38.91 -99.87 37.21 C-100.53 37.21 -101.19 37.21 -101.87 37.21 C-99.52 26.56 -92.87 15.32 -83.87 9.21 C-83.15 8.63 -82.44 8.05 -81.71 7.46 C-57.53 -11.31 -27.46 -7.77 0 0 Z " fill="#EF6B4F" stroke="#EF6B4F" transform="translate(785.8671875,300.7939453125)"/><path d="M0 0 C0.29 0.57 0.58 1.14 0.88 1.72 C6.11 11.89 11.31 21.96 17.64 31.5 C19 34 19 34 19 38 C17.08 39.65 17.08 39.65 14.37 41.27 C13.36 41.88 12.36 42.48 11.32 43.1 C6.2 46.03 1.06 48.89 -4.13 51.66 C-5.94 52.62 -7.73 53.6 -9.53 54.57 C-29.44 65.29 -29.44 65.29 -34.7 64.7 C-37.31 63.9 -39.27 62.79 -41.56 61.31 C-54.34 53.41 -67.4 48.36 -82 45 C-79.59 42.33 -77.01 40.7 -73.9 38.92 C-72.86 38.32 -71.83 37.73 -70.76 37.11 C-69.64 36.48 -68.53 35.84 -67.38 35.19 C-66.21 34.52 -65.04 33.85 -63.88 33.18 C-53.85 27.45 -43.77 21.79 -33.68 16.17 C-30.18 14.22 -26.68 12.25 -23.2 10.27 C-5.2 0 -5.2 0 0 0 Z " fill="#EF6B4F" stroke="#EF6B4F" transform="translate(614,371)"/><path d="M0 0 C2.47 2.47 2.76 4.26 3.69 7.62 C6.71 17.85 11.17 27.51 16 37 C13.24 39.98 10.69 41.91 7.07 43.73 C6.59 43.98 6.59 43.98 4.18 45.21 C3.17 45.72 2.16 46.23 1.12 46.75 C-0.96 47.82 -3.04 48.89 -5.12 49.96 C-6.13 50.48 -7.14 51 -8.18 51.53 C-15.53 55.36 -22.73 59.46 -29.62 64.06 C-33 66 -33 66 -35.03 65.79 C-42.53 62.76 -46.45 52.05 -49.88 45.38 C-50.47 44.26 -51.06 43.14 -51.67 41.98 C-52.23 40.9 -52.79 39.82 -53.37 38.71 C-53.87 37.73 -54.38 36.76 -54.9 35.75 C-56.03 32.93 -56.23 31.01 -56 28 C-46.66 22.5 -37.13 17.42 -27.49 12.45 C-20.76 8.97 -14.2 5.29 -7.74 1.33 C-4.84 -0.08 -3.18 -0.46 0 0 Z " fill="#4D4945" stroke="#4D4945" transform="translate(678,337)"/><path d="" fill="#EF6B4F" stroke="#EF6B4F" transform="translate(0,0)"/><path d="" fill="#EF6B4F" stroke="#EF6B4F" transform="translate(0,0)"/></g></svg>"""

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Image Gen</title>
<link rel="icon" href="data:image/svg+xml,__LOGO_URI__">
<style>
:root{--bg:#f4f6f9;--panel:#fff;--side:#eef1f5;--fg:#1b2230;--muted:#667085;--line:#dde2ea;--hover:#e6eaf0;
 --teal:#12a6aa;--coral:#f0705a;--accent:#0f8f93;--sel:#12a6aa;--danger:#d6453d;--ok:#1a9c5b;--warn:#c98a07;
 --shadow:0 8px 30px rgba(15,23,42,.18);--chk:#0000000f}
@media (prefers-color-scheme:dark){:root{--bg:#101826;--panel:#172133;--side:#131c2b;--fg:#e8edf4;--muted:#93a1b5;
 --line:#26324a;--hover:#1e2a40;--accent:#2fc0c4;--shadow:0 8px 30px rgba(0,0,0,.5);--chk:#ffffff12}}
*{box-sizing:border-box}html,body{height:100%}
body{margin:0;font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;background:var(--bg);color:var(--fg);
 display:flex;flex-direction:column;overflow:hidden}
button,select,input{font:inherit;color:inherit}
button{cursor:pointer;border:1px solid var(--line);background:var(--panel);border-radius:8px;padding:6px 12px}
button:hover{background:var(--hover)}button:disabled{opacity:.5;cursor:default}
button.primary{background:var(--teal);border-color:var(--teal);color:#fff}button.primary:hover{filter:brightness(1.07)}
button.danger{color:var(--danger)}button.danger.solid{background:var(--danger);border-color:var(--danger);color:#fff}
button.ghost{border-color:transparent;background:transparent}button.ghost:hover{background:var(--hover)}
code{font:12.5px ui-monospace,SFMono-Regular,Consolas,monospace;background:var(--hover);padding:2px 6px;border-radius:6px;word-break:break-all}
/* top bar */
header{display:flex;align-items:center;gap:14px;padding:10px 16px;background:var(--panel);border-bottom:1px solid var(--line);flex:none}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;font-size:16px;white-space:nowrap}
.brand svg{width:30px;height:30px}.brand b{color:var(--coral)}
#menu{display:none}
.search{flex:1;max-width:560px;margin:0 auto;position:relative}
.search input{width:100%;padding:8px 12px 8px 34px;border-radius:10px;border:1px solid var(--line);background:var(--bg);outline:none}
.search input:focus{border-color:var(--teal);box-shadow:0 0 0 3px #12a6aa33}
.search svg{position:absolute;left:10px;top:50%;transform:translateY(-50%);width:16px;height:16px;color:var(--muted)}
#status{display:flex;align-items:center;gap:8px;white-space:nowrap;color:var(--muted);font-size:13px}
.dot{width:9px;height:9px;border-radius:50%;background:var(--warn);flex:none}.dot.ready{background:var(--ok)}.dot.error{background:var(--danger)}
/* layout */
.app{flex:1;display:flex;min-height:0}
aside{width:236px;flex:none;background:var(--side);border-right:1px solid var(--line);overflow:auto;padding:12px 8px;display:flex;flex-direction:column}
aside h4{margin:14px 10px 6px;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted)}
.nav{display:flex;align-items:center;gap:8px;padding:6px 10px;border-radius:8px;cursor:pointer;color:var(--fg);user-select:none}
.nav:hover{background:var(--hover)}.nav.on{background:var(--teal);color:#fff}.nav.on .n{color:#fffc}
.nav .n{margin-left:auto;font-size:12px;color:var(--muted)}.nav.sub{padding-left:30px;font-size:13px}
.nav svg{width:16px;height:16px;flex:none}
.tw{border:0;background:none;padding:0 2px;margin-left:-4px;color:inherit;display:flex}.tw svg{transition:transform .15s}.tw.open svg{transform:rotate(90deg)}
.foot{margin-top:auto;padding:12px 10px 4px;font-size:12px;color:var(--muted)}.foot code{display:block;margin:4px 0}
main{flex:1;display:flex;flex-direction:column;min-width:0}
.bar{padding:10px 16px 8px;border-bottom:1px solid var(--line);background:var(--bg)}
.row1{display:flex;align-items:center;gap:10px;flex-wrap:wrap}.row1 .sp{flex:1}
.bar h2{margin:0;font-size:17px}.bar .count{color:var(--muted)}
.sizer{display:flex;align-items:center;gap:6px;color:var(--muted)}.sizer svg{width:15px;height:15px}
.chips{display:flex;gap:6px;overflow-x:auto;scrollbar-width:none;margin-top:8px}.chips:empty{display:none}.chips::-webkit-scrollbar{display:none}
.chip{white-space:nowrap}
.chip{border:1px solid var(--line);background:var(--panel);border-radius:99px;padding:3px 11px;font-size:12.5px;cursor:pointer;user-select:none}
.chip.on{background:var(--fg);color:var(--bg);border-color:var(--fg)}
select{padding:5px 8px;border-radius:8px;border:1px solid var(--line);background:var(--panel)}
input[type=range]{accent-color:var(--teal);width:110px}
.selbar{display:none;align-items:center;gap:8px;padding:8px 16px;background:var(--teal);color:#fff;flex-wrap:wrap}
.selbar.on{display:flex}.selbar button{background:#ffffff22;border-color:#ffffff55;color:#fff}.selbar button:hover{background:#ffffff38}
.selbar .sp{flex:1}.selbar b{font-size:15px}
#scroll{flex:1;overflow:auto;padding:4px 16px 40px;outline:none}
.group h3{position:sticky;top:0;z-index:2;margin:0;padding:12px 2px 8px;font-size:14px;background:var(--bg);display:flex;align-items:center;gap:10px}
.group h3 .gsel{font-size:12px;color:var(--muted);cursor:pointer;font-weight:500}.group h3 .gsel:hover{color:var(--teal)}
.group{content-visibility:auto;contain-intrinsic-size:auto 600px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(var(--tile,180px),1fr));gap:8px}
.tile{position:relative;aspect-ratio:1;border-radius:10px;overflow:hidden;cursor:pointer;background:
 repeating-conic-gradient(var(--chk) 0 25%,transparent 0 50%) 50%/16px 16px,var(--panel);outline:3px solid transparent;transition:outline-color .1s}
.tile img,.tile video{width:100%;height:100%;object-fit:cover;display:block;transition:transform .2s}
.tile:hover img{transform:scale(1.03)}
.tile .ck{position:absolute;top:7px;left:7px;width:22px;height:22px;border-radius:50%;border:2px solid #fff;background:#0004;
 opacity:0;transition:opacity .12s;display:grid;place-items:center;box-shadow:0 1px 4px #0006}
.tile .ck svg{width:13px;height:13px;color:#fff;opacity:0}
.tile:hover .ck,.picking .tile .ck{opacity:1}
.tile.sel{outline-color:var(--sel)}.tile.sel .ck{opacity:1;background:var(--sel);border-color:#fff}.tile.sel .ck svg{opacity:1}
.tile.sel img{transform:scale(.92);border-radius:8px}
.tile .badges{position:absolute;top:7px;right:7px;display:flex;gap:4px}
.badge{font-size:10.5px;font-weight:700;padding:1px 6px;border-radius:5px;background:#000a;color:#fff;letter-spacing:.02em}
.tile .cap{position:absolute;left:0;right:0;bottom:0;padding:18px 8px 6px;font-size:11.5px;color:#fff;
 background:linear-gradient(transparent,#000b);opacity:0;transition:opacity .12s;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tile:hover .cap{opacity:1}
.empty{display:grid;place-items:center;text-align:center;color:var(--muted);padding:80px 20px}.empty b{display:block;color:var(--fg);font-size:16px;margin-bottom:4px}
/* viewer */
#viewer{position:fixed;inset:0;z-index:20;background:#0b1018;display:none;color:#e8edf4}
#viewer.on{display:flex}
.stage{flex:1;position:relative;display:flex;flex-direction:column;min-width:0}
.vtop{display:flex;align-items:center;gap:8px;padding:10px 14px}
.vtop .t{flex:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600}
.vtop button,.vtop a{border:1px solid #ffffff2a;background:#ffffff12;color:#fff;border-radius:8px;padding:6px 11px;text-decoration:none;font-size:13px}
.vtop button:hover,.vtop a:hover{background:#ffffff26}
.vimg{flex:1;overflow:auto;display:flex;align-items:center;justify-content:center;padding:8px 60px 24px;min-height:0}
.vimg img{max-width:100%;max-height:100%;object-fit:contain;border-radius:4px;cursor:zoom-in;background:
 repeating-conic-gradient(#ffffff14 0 25%,transparent 0 50%) 50%/20px 20px}
.vimg.bg-black img,.vimg.bg-black video{background:#000}.vimg.bg-white img,.vimg.bg-white video{background:#fff}
.vimg video{max-width:100%;max-height:100%;border-radius:4px;display:none;background:
 repeating-conic-gradient(#ffffff14 0 25%,transparent 0 50%) 50%/20px 20px}.vimg.vid video{display:block}.vimg.vid img{display:none}
.vimg.zoom{align-items:flex-start;justify-content:flex-start}.vimg.zoom img{max-width:none;max-height:none;cursor:zoom-out}
.nav-btn{position:absolute;top:50%;transform:translateY(-50%);width:44px;height:64px;border-radius:10px;border:0;background:#ffffff14;color:#fff;font-size:26px}
.nav-btn:hover{background:#ffffff2a}#prev{left:8px}#next{right:8px}
.info{width:340px;flex:none;background:#131b29;border-left:1px solid #ffffff1a;overflow:auto;padding:18px}
.info.off{display:none}.info h4{margin:16px 0 6px;font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:#93a1b5}
.info h4:first-child{margin-top:0}.info .kv{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;font-size:13px}
.info .kv span:nth-child(odd){color:#93a1b5}.info .prompt{white-space:pre-wrap;font-size:13px;background:#ffffff0d;padding:10px;border-radius:8px}
.info code{background:#ffffff14;color:#e8edf4}.info button{border:1px solid #ffffff2a;background:#ffffff12;color:#fff;font-size:12px;padding:4px 10px;margin-top:6px}
/* dialogs, toasts, drop overlay */
#modal{position:fixed;inset:0;z-index:30;background:#0008;display:none;align-items:center;justify-content:center}
#modal.on{display:flex}#modal .box{background:var(--panel);border-radius:14px;padding:22px;max-width:420px;width:calc(100% - 32px);box-shadow:var(--shadow)}
#modal h3{margin:0 0 8px}#modal p{margin:0 0 18px;color:var(--muted)}#modal .acts{display:flex;justify-content:flex-end;gap:8px}
#toasts{position:fixed;left:50%;bottom:22px;transform:translateX(-50%);z-index:40;display:flex;flex-direction:column;gap:8px;align-items:center}
.toast{background:#1b2230;color:#fff;border-radius:10px;padding:10px 14px;box-shadow:var(--shadow);display:flex;gap:12px;align-items:center;font-size:13.5px}
.toast button{background:transparent;border:0;color:#5fd8db;font-weight:700;padding:0}
#drop{position:fixed;inset:0;z-index:50;background:#12a6aa2e;border:3px dashed var(--teal);display:none;align-items:center;justify-content:center;
 font-size:22px;font-weight:700;color:var(--fg);backdrop-filter:blur(2px)}#drop.on{display:flex}
#upbanner{display:none;margin:10px 16px 0;padding:14px 16px;border:2px dashed var(--line);border-radius:12px;color:var(--muted)}
#upbanner.on{display:block}
@media (max-width:760px){aside{position:fixed;z-index:15;top:52px;bottom:0;left:0;transform:translateX(-100%);transition:transform .2s;box-shadow:var(--shadow)}
 aside.open{transform:none}#menu{display:inline-flex}#status .txt{display:none}.info{display:none}.vimg{padding:8px 8px 20px}
 .nav-btn{width:36px;height:52px}.brand span{display:none}}
</style></head><body>
<header>
 <button id="menu" class="ghost" title="Folders"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18M3 12h18M3 18h18"/></svg></button>
 <div class="brand">__LOGO__<span>Image <b>Gen</b></span></div>
 <label class="search"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg>
  <input id="q" type="search" placeholder="Search names and prompts" autocomplete="off"></label>
 <div id="status"><span class="dot"></span><span class="txt">connecting...</span></div>
 <button id="upbtn" class="primary">Upload</button><input id="file" type="file" accept="image/*" multiple hidden>
</header>
<div class="app">
 <aside id="side"></aside>
 <main>
  <div class="bar"><div class="row1"><h2 id="title">All images</h2><span class="count" id="count"></span>
   <span class="sp"></span><span id="trashacts"></span>
   <select id="sort" title="Sort"><option value="new">Newest first</option><option value="old">Oldest first</option>
    <option value="name">Name</option><option value="bytes">File size</option><option value="pixels">Image size</option></select>
   <label class="sizer" title="Thumbnail size"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="4" width="7" height="7" rx="1"/></svg>
   <input id="size" type="range" min="110" max="340" step="10"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/></svg></label></div>
   <div class="chips" id="chips"></div></div>
  <div class="selbar" id="selbar"><b id="selcount"></b><button id="selall">Select all</button><button id="selnone">Clear</button>
   <span class="sp"></span><span id="selacts"></span></div>
  <div id="upbanner">Drop images anywhere on this page, or click <b>Upload</b>. Then give an image's reference (click it, then
   <b>Copy reference</b>) to your AI app as an input for <code>edit_image</code>, <code>generate_panorama</code>,
   <code>remove_background</code> or any other tool.</div>
  <div id="scroll" tabindex="-1"></div>
 </main>
</div>
<div id="viewer"><div class="stage"><div class="vtop"><div class="t" id="vtitle"></div><span id="vpos" style="opacity:.7;font-size:13px"></span>
 <span id="vbtns"></span><button id="vinfo" title="Info (I)">Info</button><button id="vclose" title="Close (Esc)">&#10005;</button></div>
 <div class="vimg" id="vimg"><img id="vpic" alt=""><video id="vvid" controls playsinline preload="metadata"></video></div><button class="nav-btn" id="prev" title="Previous">&#8249;</button>
 <button class="nav-btn" id="next" title="Next">&#8250;</button></div><div class="info" id="vpanel"></div></div>
<div id="modal"><div class="box"><h3 id="mtitle"></h3><p id="mtext"></p><div class="acts"><button id="mno">Cancel</button>
 <button id="myes" class="danger solid"></button></div></div></div>
<div id="toasts"></div><div id="drop">Drop images to upload</div>
<script>
const $=s=>document.querySelector(s), esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const enc=p=>p.split('/').map(encodeURIComponent).join('/');
const ICON={all:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
 sparkle:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 3l1.9 5.6L19.5 10l-5.6 1.9L12 17.5l-1.9-5.6L4.5 10l5.6-1.4z"/></svg>',
 folder:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/></svg>',
 up:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M12 16V4m0 0-4 4m4-4 4 4M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>',
 trash:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/></svg>',
 chev:'<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.5"><path d="m9 6 6 6-6 6"/></svg>',
 check:'<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5"><path d="m5 12 5 5 9-10"/></svg>'};
const S={items:[],trash:[],kinds:{},folders:[],trashCount:0,allowDelete:true,keepDays:7,view:'all',kind:'',q:'',sort:'new',
 size:180,sel:new Set(),anchor:null,shown:[],open:{results:true,uploads:true},cur:-1,jobsDone:null};
try{const p=JSON.parse(localStorage.getItem('imagegen.gallery')||'{}');S.sort=p.sort||S.sort;S.size=p.size||S.size;Object.assign(S.open,p.open||{})}catch(e){}
function savePrefs(){try{localStorage.setItem('imagegen.gallery',JSON.stringify({sort:S.sort,size:S.size,open:S.open}))}catch(e){}}
function readHash(){const h=new URLSearchParams(location.hash.slice(1));S.view=h.get('view')||'all';S.kind=h.get('kind')||'';S.q=h.get('q')||'';
 S.openFile=h.get('open')||''}
function writeHash(){const h=new URLSearchParams();if(S.view!=='all')h.set('view',S.view);if(S.kind)h.set('kind',S.kind);if(S.q)h.set('q',S.q);
 if(S.openFile)h.set('open',S.openFile);
 const s=h.toString();history.replaceState(null,'',s?'#'+s:location.pathname)}
// ---------------------------------------------------------------- data
async function load(){try{const r=await fetch('api/library');const d=await r.json();S.items=d.items;S.kinds=d.kinds;S.folders=d.folders;
 S.trashCount=d.trash;S.allowDelete=d.allow_delete;S.keepDays=d.keep_days;if(S.view==='trash')await loadTrash();render();
 if(S.openFile&&S.cur<0){const i=S.shown.findIndex(e=>e.file===S.openFile);if(i>=0)openViewer(i);else{S.openFile='';writeHash()}}}catch(e){toast('Could not load the images: '+e)}}
async function loadTrash(){const r=await fetch('api/trash');const d=await r.json();S.trash=d.items;S.trashCount=d.items.length}
async function post(url,body){const r=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const d=await r.json().catch(()=>({}));if(!r.ok)throw new Error(d.error||r.statusText);return d}
// ---------------------------------------------------------------- filtering
const isTrash=()=>S.view==='trash';
function inView(e){if(S.view==='all')return true;if(S.view==='results')return!e.file.startsWith('uploads/');if(S.view==='uploads')return e.file.startsWith('uploads/');
 if(S.view.startsWith('folder:'))return e.folder===S.view.slice(7);return true}
function words(e){const i=e.info||{};return(e.file+' '+(S.kinds[e.kind]||e.kind)+' '+(e.tool||'')+' '+Object.values(i).join(' ')).toLowerCase()}
function filtered(){let list=isTrash()?S.trash:S.items.filter(inView);const base=list;if(S.kind)list=list.filter(e=>e.kind===S.kind);
 if(S.q){const ws=S.q.toLowerCase().split(/\s+/).filter(Boolean);list=list.filter(e=>{const t=words(e);return ws.every(w=>t.includes(w))})}
 const k={new:(a,b)=>b.modified-a.modified,old:(a,b)=>a.modified-b.modified,name:(a,b)=>a.name.localeCompare(b.name),
  bytes:(a,b)=>b.bytes-a.bytes,pixels:(a,b)=>(b.width*b.height||0)-(a.width*a.height||0)}[S.sort];
 const key=isTrash()&&(S.sort==='new'||S.sort==='old')?(S.sort==='new'?(a,b)=>b.deleted-a.deleted:(a,b)=>a.deleted-b.deleted):k;
 return{list:[...list].sort(key),base}}
function dayLabel(ms){const d=new Date(ms),t=new Date();t.setHours(0,0,0,0);const d0=new Date(d);d0.setHours(0,0,0,0);
 const days=Math.round((t-d0)/864e5);if(days===0)return'Today';if(days===1)return'Yesterday';
 if(days<7)return d.toLocaleDateString(undefined,{weekday:'long',month:'short',day:'numeric'});
 return d.toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'})}
const fmtBytes=b=>b>=1048576?(b/1048576).toFixed(1)+' MB':Math.max(1,Math.round(b/1024))+' KB';
// ---------------------------------------------------------------- rendering
function viewTitle(){if(S.view==='all')return'All images';if(S.view==='results')return'Results';if(S.view==='uploads')return'Uploads';
 if(S.view==='trash')return'Trash';const f=S.view.slice(7);return f.startsWith('uploads/')?'Uploads / '+f.slice(8):folderName(f)}
function folderName(f){if(/^\d{4}-\d{2}-\d{2}$/.test(f)){const d=new Date(f+'T12:00:00');return d.toLocaleDateString(undefined,{year:'numeric',month:'short',day:'numeric'})}return f}
function nav(id,label,count,icon,cls=''){return`<div class="nav ${cls} ${S.view===id?'on':''}" data-view="${esc(id)}">${icon||''}<span>${esc(label)}</span><span class="n">${count??''}</span></div>`}
function renderSide(){const res=S.items.filter(e=>!e.file.startsWith('uploads/')).length,ups=S.items.length-res;
 const rf=S.folders.filter(f=>!f.path.startsWith('uploads')),uf=S.folders.filter(f=>f.path.startsWith('uploads'));
 const tw=k=>`<button class="tw ${S.open[k]?'open':''}" data-tw="${k}">${ICON.chev}</button>`;
 let h='<h4>Library</h4>'+nav('all','All images',S.items.length,ICON.all);
 h+=nav('results','Results',res,tw('results')+ICON.sparkle);
 if(S.open.results)h+=rf.map(f=>nav('folder:'+f.path,folderName(f.path),f.count,'','sub')).join('');
 h+=nav('uploads','Uploads',ups,tw('uploads')+ICON.up);
 if(S.open.uploads)h+=uf.map(f=>nav('folder:'+f.path,f.path.slice(8)||'uploads',f.count,'','sub')).join('');
 h+='<h4>&nbsp;</h4>'+nav('trash','Trash',S.trashCount||'',ICON.trash);
 h+=`<div class="foot">MCP endpoint (Streamable HTTP, no login)<code id="ep">${esc(location.origin+'__MCP_PATH__')}</code><button id="epcopy" class="ghost" style="padding:2px 6px;font-size:12px">Copy</button></div>`;
 $('#side').innerHTML=h}
function renderBar(base){$('#title').textContent=viewTitle();const present=[...new Set(base.map(e=>e.kind))];
 const order=Object.keys(S.kinds).concat(['other']);present.sort((a,b)=>order.indexOf(a)-order.indexOf(b));
 $('#chips').innerHTML=present.length>1?[`<span class="chip ${S.kind?'':'on'}" data-kind="">All</span>`].concat(present.map(k=>
  `<span class="chip ${S.kind===k?'on':''}" data-kind="${esc(k)}">${esc(S.kinds[k]||'Other')}</span>`)).join(''):'';
 $('#trashacts').innerHTML=isTrash()&&S.allowDelete&&S.trash.length?'<button class="danger" id="empty">Empty trash</button>':'';
 $('#sort').value=S.sort;$('#size').value=S.size}
function tile(e,i){const tr=isTrash();const b=[];if(e.panorama)b.push('360°');if(e.svg)b.push('SVG');
 if(e.video)b.push('&#9654;'+(e.info&&e.info.seconds?` ${Math.round(e.info.seconds)} s`:''));
 const s=S.size>220?512:256,src=`thumbs/${enc(e.file)}?s=${s}${tr?'&trash=1':''}`;
 const dim=e.width?` · ${e.width}x${e.height}`:'';
 const pic=e.video&&!e.poster&&!tr?`<video muted playsinline preload="metadata" src="outputs/${enc(e.file)}#t=0.1"></video>`
  :`<img loading="lazy" decoding="async" src="${src}" alt="">`;
 return`<div class="tile ${S.sel.has(e.file)?'sel':''}" data-i="${i}" title="${esc(e.name)}">${pic}
 <span class="ck" data-ck="${i}">${ICON.check}</span><span class="badges">${b.map(x=>`<span class="badge">${x}</span>`).join('')}</span>
 <span class="cap">${esc(S.kinds[e.kind]||'')}${dim}</span></div>`}
function render(){renderSide();const {list,base}=filtered();S.shown=list;renderBar(base);
 for(const f of [...S.sel])if(!list.some(e=>e.file===f))S.sel.delete(f);
 $('#count').textContent=list.length+(list.length===1?' image':' images');
 document.documentElement.style.setProperty('--tile',S.size+'px');
 const sc=$('#scroll');
 if(!list.length){sc.innerHTML=`<div class="empty"><div><b>${isTrash()?'The trash is empty':S.q||S.kind?'Nothing matches':'No images yet'}</b>${
  isTrash()?'Deleted images stay here until you empty the trash'+(S.keepDays?` or for ${S.keepDays} days`:'')+'.':
  S.q||S.kind?'Try other words or another filter.':'Ask your AI app for an image, or drop images here to upload them.'}</div></div>`;renderSel();return}
 const byDay=S.sort==='new'||S.sort==='old';let h='',last=null,open=false;
 list.forEach((e,i)=>{const lab=byDay?dayLabel(isTrash()?e.deleted:e.modified):'';
  if(lab!==last||!open){if(open)h+='</div></div>';h+=`<div class="group">${byDay?`<h3>${esc(lab)}<span class="gsel" data-gsel="${esc(lab)}">Select</span></h3>`:'<div style="height:10px"></div>'}<div class="grid">`;last=lab;open=true}
  h+=tile(e,i)});
 h+='</div></div>';sc.innerHTML=h;renderSel()}
function renderSel(){const n=S.sel.size;$('#selbar').classList.toggle('on',n>0);document.body.classList.toggle('picking',n>0);
 $('#selcount').textContent=n+(n===1?' selected':' selected');
 $('#selacts').innerHTML=isTrash()?(S.allowDelete?'<button id="restore">Restore</button><button id="purge">Delete forever</button>':'')
  :'<button id="dl">Download</button>'+(S.allowDelete?'<button id="del">Move to trash</button>':'');
 document.querySelectorAll('.tile').forEach(t=>t.classList.toggle('sel',S.sel.has(S.shown[+t.dataset.i].file)))}
// ---------------------------------------------------------------- selection
function toggle(i,on){const f=S.shown[i].file;(on??!S.sel.has(f))?S.sel.add(f):S.sel.delete(f);S.anchor=i}
function range(i){const a=S.anchor??i;const [lo,hi]=a<i?[a,i]:[i,a];for(let k=lo;k<=hi;k++)S.sel.add(S.shown[k].file)}
$('#scroll').addEventListener('click',e=>{const g=e.target.closest('[data-gsel]');if(g){const lab=g.dataset.gsel;
  const idx=S.shown.map((x,i)=>i).filter(i=>dayLabel(isTrash()?S.shown[i].deleted:S.shown[i].modified)===lab);
  const all=idx.every(i=>S.sel.has(S.shown[i].file));idx.forEach(i=>toggle(i,!all));renderSel();return}
 const t=e.target.closest('.tile');if(!t)return;const i=+t.dataset.i;
 if(e.target.closest('[data-ck]')||e.ctrlKey||e.metaKey){toggle(i)}else if(e.shiftKey){range(i)}else if(S.sel.size){toggle(i)}else{openViewer(i);return}
 renderSel()});
$('#selall').onclick=()=>{S.shown.forEach(e=>S.sel.add(e.file));renderSel()};$('#selnone').onclick=()=>{S.sel.clear();renderSel()};
$('#selbar').addEventListener('click',async e=>{const id=e.target.id,files=[...S.sel];if(!files.length)return;
 if(id==='del')trashFiles(files);if(id==='dl')download(files);if(id==='restore')restore(files);
 if(id==='purge')confirmBox('Delete forever?',`${files.length} image${files.length>1?'s':''} will be deleted for good. This cannot be undone.`,'Delete forever',()=>purge(files))});
// ---------------------------------------------------------------- actions
function confirmBox(title,text,yes,fn){$('#mtitle').textContent=title;$('#mtext').textContent=text;$('#myes').textContent=yes;$('#modal').classList.add('on');
 const close=()=>$('#modal').classList.remove('on');$('#mno').onclick=close;$('#myes').onclick=()=>{close();fn()};$('#myes').focus()}
async function trashFiles(files){try{const d=await post('api/delete',{files});S.sel.clear();if(S.cur>=0)closeViewer();await load();
 toast(`${d.moved.length} image${d.moved.length===1?'':'s'} moved to the trash`,'Undo',async()=>{await post('api/restore',{files:d.moved});await load();toast('Restored')})}
 catch(e){toast('Could not delete: '+e.message)}}
async function restore(files){try{const d=await post('api/restore',{files});S.sel.clear();await load();
 toast(`${d.restored.length} image${d.restored.length===1?'':'s'} restored`)}catch(e){toast('Could not restore: '+e.message)}}
async function purge(files){try{const d=await post('api/trash/empty',files?{files}:{});S.sel.clear();await load();
 toast(`${d.deleted} image${d.deleted===1?'':'s'} deleted for good`)}catch(e){toast('Could not delete: '+e.message)}}
async function download(files){if(files.length===1){const a=document.createElement('a');a.href='outputs/'+enc(files[0]);a.download=files[0].split('/').pop();a.click();return}
 toast(`Zipping ${files.length} images...`);try{const r=await fetch('api/zip',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({files})});
 if(!r.ok)throw new Error((await r.json()).error);const blob=await r.blob();const a=document.createElement('a');a.href=URL.createObjectURL(blob);
 a.download=(r.headers.get('content-disposition')||'').match(/filename="?([^";]+)/)?.[1]||'images.zip';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),6e4)}
 catch(e){toast('Could not download: '+e.message)}}
function toast(text,action,fn){const t=document.createElement('div');t.className='toast';t.innerHTML=`<span>${esc(text)}</span>`;
 if(action){const b=document.createElement('button');b.textContent=action;b.onclick=()=>{t.remove();fn()};t.appendChild(b)}
 $('#toasts').appendChild(t);setTimeout(()=>t.remove(),action?8000:3500)}
// navigator.clipboard exists only on https and localhost pages; on a plain-http network address use execCommand
async function copyText(t){if(navigator.clipboard&&window.isSecureContext){try{await navigator.clipboard.writeText(t);return true}catch(e){}}
 const a=document.createElement('textarea');a.value=t;a.setAttribute('readonly','');a.style.cssText='position:fixed;top:-1000px;opacity:0';
 document.body.appendChild(a);a.select();let ok=false;try{ok=document.execCommand('copy')}catch(e){}a.remove();return ok}
async function copy(t,what){toast(await copyText(t)?`${what} copied`:'Select the text and press Ctrl+C')}
// ---------------------------------------------------------------- viewer
function openViewer(i){S.cur=i;$('#viewer').classList.add('on');showCur()}
function stopVideo(){const v=$('#vvid');v.pause();v.removeAttribute('src');v.removeAttribute('poster');v.load()}
function closeViewer(){S.cur=-1;S.openFile='';writeHash();stopVideo();$('#viewer').classList.remove('on');$('#vimg').classList.remove('zoom','vid')}
function showCur(){const e=S.shown[S.cur];if(!e)return closeViewer();const tr=isTrash();if(!tr){S.openFile=e.file;writeHash()}
 $('#vimg').classList.remove('zoom');stopVideo();const vid=!!e.video&&!tr;$('#vimg').classList.toggle('vid',vid);
 if(vid){const v=$('#vvid');if(e.poster)v.poster='outputs/'+enc(e.poster);v.src='outputs/'+enc(e.file);v.play().catch(()=>{})}
 else $('#vpic').src=tr||e.video?`thumbs/${enc(e.file)}?s=512${tr?'&trash=1':''}`:'outputs/'+enc(e.file);
 $('#vtitle').textContent=e.name;$('#vpos').textContent=`${S.cur+1} / ${S.shown.length}`;
 const btn=[];if(!tr){btn.push(`<a href="outputs/${enc(e.file)}" download>Download</a>`,`<a href="outputs/${enc(e.file)}" target="_blank">Open</a>`);
  if(e.panorama)btn.push(`<a href="view/${enc(e.file)}" target="_blank">360 viewer</a>`);if(e.svg)btn.push(`<a href="outputs/${enc(e.svg)}" target="_blank">SVG</a>`);
  if(S.allowDelete)btn.push('<button id="vdel">Move to trash</button>')}else if(S.allowDelete)btn.push('<button id="vrest">Restore</button>');
 $('#vbtns').innerHTML=btn.join(' ');
 const tool={generate:'generate_image',edit:'edit_image',panorama:'generate_panorama',upscale:'upscale_image',
  vectorize:'vectorize_image'}[e.tool]||e.tool||'';
 const i=e.info||{},rows=[['Type',S.kinds[e.kind]||'Other'],['Size',e.width?`${e.width} x ${e.height}`:''],
  ['Length',e.video&&i.seconds?`${i.seconds} s`:''],['File',fmtBytes(e.bytes)],
  ['Date',new Date(e.modified).toLocaleString()],['Folder',e.folder||'outputs'],['Tool',tool]];
 const skip=new Set(['prompt','negative_prompt','width','height','seconds','poster']),label=k=>({cfg_scale:'CFG scale'}[k]||k.charAt(0).toUpperCase()+k.slice(1).replace(/_/g,' '));
 for(const [k,v] of Object.entries(i))if(!skip.has(k)&&v!==''&&v!=null)rows.push([label(k),v]);
 let h='';
 if(i.prompt)h+=`<h4>Prompt</h4><div class="prompt">${esc(i.prompt)}</div><button data-copy="${esc(i.prompt)}" data-what="Prompt">Copy prompt</button>`;
 else if(e.kind!=='upload'&&!e.tool)h+='<h4>Prompt</h4><div class="prompt" style="opacity:.7">Not recorded: the server keeps the prompt of images made since this version.</div>';
 if(i.negative_prompt)h+=`<h4>Negative prompt</h4><div class="prompt">${esc(i.negative_prompt)}</div>`;
 h+=`<h4>Reference</h4><code>${esc(e.file)}</code><br><button data-copy="${esc(e.file)}" data-what="Reference">Copy reference</button>`;
 h+='<h4>Details</h4><div class="kv">'+rows.filter(r=>r[1]!==''&&r[1]!=null).map(r=>`<span>${esc(r[0])}</span><span>${esc(r[1])}</span>`).join('')+'</div>';
 $('#vpanel').innerHTML=h;$('#prev').style.visibility=S.cur>0?'':'hidden';$('#next').style.visibility=S.cur<S.shown.length-1?'':'hidden'}
$('#prev').onclick=()=>{if(S.cur>0){S.cur--;showCur()}};$('#next').onclick=()=>{if(S.cur<S.shown.length-1){S.cur++;showCur()}};
$('#vclose').onclick=closeViewer;$('#vinfo').onclick=()=>$('#vpanel').classList.toggle('off');
$('#vpic').onclick=()=>$('#vimg').classList.toggle('zoom');
$('#vimg').onclick=e=>{if(e.target.id==='vimg')closeViewer()};
$('#viewer').addEventListener('click',e=>{const c=e.target.closest('[data-copy]');if(c)copy(c.dataset.copy,c.dataset.what);
 if(e.target.id==='vdel'){const f=S.shown[S.cur].file;trashFiles([f])}if(e.target.id==='vrest'){restore([S.shown[S.cur].file]);closeViewer()}});
// ---------------------------------------------------------------- side bar, bar, keys
$('#side').addEventListener('click',e=>{const t=e.target.closest('[data-tw]');if(t){S.open[t.dataset.tw]=!S.open[t.dataset.tw];savePrefs();renderSide();return}
 if(e.target.id==='epcopy')return copy(location.origin+'__MCP_PATH__','Endpoint');
 const n=e.target.closest('[data-view]');if(!n)return;S.view=n.dataset.view;S.kind='';S.sel.clear();writeHash();$('#side').classList.remove('open');
 (S.view==='trash'?loadTrash():Promise.resolve()).then(render);$('#scroll').scrollTop=0});
$('#chips').addEventListener('click',e=>{const c=e.target.closest('[data-kind]');if(!c)return;S.kind=c.dataset.kind;writeHash();render()});
$('#trashacts').addEventListener('click',e=>{if(e.target.id==='empty')confirmBox('Empty the trash?',`${S.trash.length} image${S.trash.length>1?'s':''} will be deleted for good.`,'Empty trash',()=>purge(null))});
$('#sort').onchange=e=>{S.sort=e.target.value;savePrefs();render()};
$('#size').oninput=e=>{S.size=+e.target.value;document.documentElement.style.setProperty('--tile',S.size+'px')};
$('#size').onchange=()=>{savePrefs();render()};
let qt;$('#q').oninput=e=>{clearTimeout(qt);qt=setTimeout(()=>{S.q=e.target.value.trim();writeHash();render()},150)};
$('#menu').onclick=()=>$('#side').classList.toggle('open');
document.addEventListener('keydown',e=>{const typing=/INPUT|SELECT|TEXTAREA/.test(document.activeElement.tagName);
 if($('#modal').classList.contains('on')){if(e.key==='Escape')$('#modal').classList.remove('on');return}
 if(S.cur>=0){if(e.key==='Escape')closeViewer();else if(e.key==='ArrowLeft')$('#prev').click();else if(e.key==='ArrowRight')$('#next').click();
  else if(e.key==='i'||e.key==='I')$('#vinfo').click();else if((e.key==='Delete')&&S.allowDelete&&!isTrash())trashFiles([S.shown[S.cur].file]);return}
 if(typing){if(e.key==='Escape')e.target.blur();return}
 if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='a'){e.preventDefault();$('#selall').click()}
 else if(e.key==='Escape'){S.sel.clear();renderSel()}
 else if((e.key==='Delete'||e.key==='Backspace')&&S.sel.size&&S.allowDelete){e.preventDefault();isTrash()?$('#purge').click():$('#del').click()}
 else if(e.key==='/'){e.preventDefault();$('#q').focus()}});
// ---------------------------------------------------------------- upload
async function upload(files){files=[...files].filter(f=>f.type.startsWith('image/'));if(!files.length)return;const done=[];
 for(const [k,f] of files.entries()){toast(`Uploading ${k+1} of ${files.length}: ${f.name}`);try{const r=await fetch('upload?name='+encodeURIComponent(f.name),
  {method:'POST',headers:{'Content-Type':f.type||'application/octet-stream'},body:f});const d=await r.json();if(d.error)throw new Error(d.error);done.push(d.file)}
  catch(e){toast(`${f.name}: ${e.message}`)}}
 if(!done.length)return;S.view='uploads';S.kind='';S.q='';$('#q').value='';writeHash();await load();S.sel=new Set(done);renderSel();
 if(done.length===1)toast(`Uploaded: ${done[0]}`,'Copy reference',()=>copy(done[0],'Reference'));else toast(`${done.length} images uploaded`)}
$('#upbtn').onclick=()=>$('#file').click();$('#file').onchange=e=>{upload(e.target.files);e.target.value=''};
let dragN=0;window.addEventListener('dragenter',e=>{if(![...e.dataTransfer.types].includes('Files'))return;dragN++;$('#drop').classList.add('on')});
window.addEventListener('dragleave',()=>{if(--dragN<=0){dragN=0;$('#drop').classList.remove('on')}});
window.addEventListener('dragover',e=>e.preventDefault());
window.addEventListener('drop',e=>{e.preventDefault();dragN=0;$('#drop').classList.remove('on');upload(e.dataTransfer.files)});
// ---------------------------------------------------------------- status
async function status(){try{const s=await(await fetch('api/status')).json();const cls=s.state==='ready'?'ready':s.state==='error'?'error':'';
 const model={turbo:'Turbo',uncensored:'Non-Turbo',base:'Base'}[s.model.variant]||s.model.variant;
 let t=s.state==='ready'?`Ready · ${s.device.toUpperCase()} · ${model} ${s.model.quant}`:s.state==='downloading'&&s.download.percent!=null?
  `Downloading models ${s.download.percent}% of ${s.download.total_gb} GB`:s.state==='error'?'Error: '+(s.error||''):s.state.charAt(0).toUpperCase()+s.state.slice(1)+'...';
 if(s.running_jobs&&s.running_jobs.length)t=s.running_jobs.map(j=>`${j.kind} ${j.progress_percent}%`).join(', ');
 $('#status').innerHTML=`<span class="dot ${cls}"></span><span class="txt">${esc(t)}</span>`;$('#status').title=s.error||t;
 const done=(s.jobs_done??0)+'|'+(s.running_jobs||[]).length;if(S.jobsDone!==null&&done!==S.jobsDone)load();S.jobsDone=done}
 catch(e){$('#status').innerHTML='<span class="dot error"></span><span class="txt">server not reachable</span>'}}
readHash();$('#q').value=S.q;if(/\/upload$/.test(location.pathname))$('#upbanner').classList.add('on');
window.addEventListener('hashchange',()=>{const was=S.openFile;readHash();$('#q').value=S.q;if(S.openFile===was)render()});
load();status();setInterval(status,4000);setInterval(()=>{if(S.cur<0&&!S.sel.size)load()},30000);
</script></body></html>"""

PAGE = PAGE.replace("__LOGO__", LOGO).replace("__LOGO_URI__", quote(LOGO))
