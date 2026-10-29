"""Frozen Windows entry point; packaging never includes user configuration."""
from bridge.desktop import main

if __name__ == "__main__":
    main()
