#!/usr/bin/env python3
"""Make only the border-connected near-white background transparent."""

from collections import deque
from pathlib import Path
import sys

from PIL import Image


source = Path(sys.argv[1])
destination = Path(sys.argv[2])
image = Image.open(source).convert("RGBA")
pixels = image.load()
width, height = image.size

key = pixels[0, 0][:3]
visited = bytearray(width * height)
queue: deque[tuple[int, int]] = deque()


def distance(x: int, y: int) -> float:
    red, green, blue, _ = pixels[x, y]
    return ((red - key[0]) ** 2 + (green - key[1]) ** 2 + (blue - key[2]) ** 2) ** 0.5


def enqueue(x: int, y: int) -> None:
    index = y * width + x
    if not visited[index] and distance(x, y) <= 100:
        visited[index] = 1
        queue.append((x, y))


for x in range(width):
    enqueue(x, 0)
    enqueue(x, height - 1)
for y in range(height):
    enqueue(0, y)
    enqueue(width - 1, y)

while queue:
    x, y = queue.popleft()
    if x:
        enqueue(x - 1, y)
    if x + 1 < width:
        enqueue(x + 1, y)
    if y:
        enqueue(x, y - 1)
    if y + 1 < height:
        enqueue(x, y + 1)

for y in range(height):
    for x in range(width):
        if not visited[y * width + x]:
            continue
        red, green, blue, _ = pixels[x, y]
        color_distance = distance(x, y)
        alpha = 0 if color_distance <= 5 else min(255, round((color_distance - 5) / 95 * 255))
        pixels[x, y] = (red, green, blue, alpha)

image.save(destination)
