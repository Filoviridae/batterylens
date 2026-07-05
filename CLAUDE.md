# BatteryLens Development Guidelines

## Communication style
- Before EVERY action, explain in plain English what you are about to do and why
- After completing a change, summarize what you changed and what effect it should have
- If something doesn't work, explain your diagnosis before proposing a fix
- Never make multiple changes at once without explaining each one first

## Project context
This is BatteryLens - a GTK3 native Python battery history viewer for Linux.
Main file: battery_lens_gtk.py (~1850 lines, single file)
Run with: ~/.local/share/batterylens/venv/bin/python battery_lens_gtk.py
