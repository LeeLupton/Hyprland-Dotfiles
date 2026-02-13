import json
import logging
import sys
import os
import traceback
from pathlib import Path

# Configuration
LOG_DIR = Path.home() / ".cache" / "waybar-scripts"
CONFIG_DIR = Path.home() / ".config" / "waybar-scripts"

LOG_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_DIR.mkdir(parents=True, exist_ok=True)

def setup_logger(name):
    """Sets up a logger for the given module name."""
    logger = logging.getLogger(name)
    logger.setLevel(logging.INFO)
    
    # File handler
    log_file = LOG_DIR / f"{name}.log"
    file_handler = logging.FileHandler(log_file)
    formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)
    
    return logger

def load_config(name, default_config=None):
    """Loads configuration for the given module name."""
    config_file = CONFIG_DIR / f"{name}.json"
    if not config_file.exists():
        if default_config:
            with open(config_file, 'w') as f:
                json.dump(default_config, f, indent=4)
            return default_config
        return {}
    
    try:
        with open(config_file, 'r') as f:
            return json.load(f)
    except json.JSONDecodeError:
        logging.getLogger(name).error(f"Failed to decode config file: {config_file}")
        return default_config or {}

def output_json(data):
    """Prints data as JSON to stdout and exits."""
    print(json.dumps(data), flush=True)

def output_error(message, tooltip=None):
    """Outputs a Waybar-compatible error message."""
    output_json({
        "text": "Error",
        "tooltip": tooltip or message,
        "class": "error"
    })

def safe_run(func):
    """Decorator to catch exceptions and log/output them safely."""
    def wrapper(*args, **kwargs):
        try:
            return func(*args, **kwargs)
        except Exception as e:
            # Get the logger for the module if possible, otherwise use root
            logger = logging.getLogger(func.__module__)
            logger.error(f"Exception in {func.__name__}: {str(e)}")
            logger.error(traceback.format_exc())
            output_error("Script Error", str(e))
            sys.exit(1)
    return wrapper
