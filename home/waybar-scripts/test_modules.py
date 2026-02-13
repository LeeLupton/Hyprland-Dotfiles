#!/usr/bin/env python3

import subprocess
import json
import sys
import os

MODULES = [
    "./waybar-network.py",
    "./waybar-audio.py"
]

def test_module(script_path):
    print(f"Testing {script_path}...")
    if not os.access(script_path, os.X_OK):
        # Try to make it executable
        try:
            os.chmod(script_path, 0o755)
        except OSError:
            print(f"  Warning: Could not make {script_path} executable.")

    try:
        # Run the script
        result = subprocess.run(
            [script_path], 
            capture_output=True, 
            text=True, 
            timeout=5
        )
        
        if result.returncode != 0:
            print(f"  FAILED: Script exited with code {result.returncode}")
            print(f"  Stderr: {result.stderr.strip()}")
            return False
            
        # Parse Output
        try:
            data = json.loads(result.stdout)
            
            # Check required Waybar keys
            required_keys = ["text", "tooltip"]
            missing_keys = [k for k in required_keys if k not in data]
            
            if missing_keys:
                print(f"  FAILED: Missing JSON keys: {missing_keys}")
                return False
                
            print(f"  SUCCESS: {data['text']}")
            return True
            
        except json.JSONDecodeError:
            print(f"  FAILED: Invalid JSON output")
            print(f"  Output: {result.stdout.strip()}")
            return False
            
    except subprocess.TimeoutExpired:
        print(f"  FAILED: Script timed out (Optimization issue?)")
        return False
    except Exception as e:
        print(f"  FAILED: Execution error: {e}")
        return False

def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    
    success = True
    for module in MODULES:
        if not test_module(module):
            success = False
            
    if success:
        print("\nAll modules passed basic validation.")
        sys.exit(0)
    else:
        print("\nSome modules failed.")
        sys.exit(1)

if __name__ == '__main__':
    main()
