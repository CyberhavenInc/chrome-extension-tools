# chrome-extension-checks
This repository contains various scripts and resources that assist in the identifying Chrome extension versions, and searching Chrome local storage for potentially malicious entries 


scan_wrapper.sh
---
This script, scan_wrapper.sh, checks all browser extensions installed on your machine. If it finds any malicious code or suspicious artifacts in the extensions' local storage, it will print out the names of those extensions. If everything's clean, it won't output anything

To run the script, just copy and paste this command into your terminal:
```bash
curl -sL https://raw.githubusercontent.com/CyberhavenInc/chrome-extension-tools/main/chrome-extensions-scanner/scan_wrapper.sh | bash -s
```
