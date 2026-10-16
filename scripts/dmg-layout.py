#!/usr/bin/env python3
"""Write installer layout without changing the user's Finder preferences."""
from pathlib import Path
import sys

from ds_store import DSStore

with DSStore.open(str(Path(sys.argv[1]) / ".DS_Store"), "w+") as store:
    store["."]["bwsp"] = {
        "WindowBounds": "{{400, 240}, {560, 360}}",
        "ShowStatusBar": False,
        "ShowToolbar": False,
        "ShowTabView": False,
        "ShowPathbar": False,
        "ShowSidebar": False,
        "SidebarWidth": 0,
        "ContainerShowSidebar": False,
    }
    store["."]["icvp"] = {
        "viewOptionsVersion": 1,
        "backgroundType": 1,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "arrangeBy": "none",
        "iconSize": 100.0,
        "labelOnBottom": True,
        "showItemInfo": False,
        "showIconPreview": True,
        "textSize": 14.0,
    }
    store["."]["vSrn"] = ("long", 1)
    store["."]["vstl"] = ("type", b"icnv")
    store["QuotaPeek.app"]["Iloc"] = (140, 150)
    store["Applications"]["Iloc"] = (420, 150)
