#!/usr/bin/env python3
"""
DeepSeek OCR extraction script for local processing.
Requires: pip install transformers pillow torch
"""

import sys
import json
from pathlib import Path

try:
    from transformers import AutoModel
    from PIL import Image
except ImportError as e:
    print(json.dumps({"error": f"Missing dependencies: {e}. Install with: pip install transformers pillow torch"}))
    sys.exit(1)

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: python3 ocr_extract.py <image_path>"}))
        sys.exit(1)
    
    image_path = sys.argv[1]
    
    if not Path(image_path).exists():
        print(json.dumps({"error": f"Image file not found: {image_path}"}))
        sys.exit(1)
    
    try:
        # Load model (will download on first run)
        print(json.dumps({"status": "Loading DeepSeek-OCR model..."}), file=sys.stderr)
        model = AutoModel.from_pretrained("deepseek-ai/DeepSeek-OCR", trust_remote_code=True, dtype="auto")
        
        # Load and process image
        print(json.dumps({"status": "Processing image..."}), file=sys.stderr)
        image = Image.open(image_path)
        result = model(image)
        
        # Extract text from result
        # The exact format depends on the model output - adjust as needed
        if isinstance(result, dict):
            text = result.get("text", str(result))
        elif isinstance(result, str):
            text = result
        else:
            text = str(result)
        
        # Return JSON with extracted text
        output = {"text": text}
        print(json.dumps(output))
        
    except Exception as e:
        print(json.dumps({"error": f"OCR processing failed: {str(e)}"}))
        sys.exit(1)

if __name__ == "__main__":
    main()
