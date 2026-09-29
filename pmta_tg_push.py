#!/usr/bin/env python3
"""PowerMTA local metrics logger (Safe clean edition - Telegram disabled).
Placeholders preserved for configure_script.py compatibility:
{{DKIM_SELECTOR}}
{{FULL_DOMAIN}}
{{EMAIL_USER}}
{{EMAIL_PASS_B64}}
"""
import sys
import time

def main():
    # Safe dummy worker - does not leak credentials or send network requests
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
