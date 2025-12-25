#!/usr/bin/env python3
import json
import sys


def infer_type(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "real"
    if isinstance(value, str):
        return "string"
    if isinstance(value, (dict, list)):
        return "dynamic"
    return "string"


# Terraform external provider passes input via stdin
query = json.load(sys.stdin)
path = query["file"]

with open(path) as f:
    data = json.load(f)

columns = []

for key, value in data.items():
    columns.append({"name": key, "type": infer_type(value)})

# external provider requires JSON object output
print(json.dumps({"columns": json.dumps(columns)}))
