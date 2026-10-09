# Hermes mini-gibson profile

This directory will hold the portable Hermes profile/configuration after the exact Hermes configuration format in the target environment is verified.

Do not guess or commit a fabricated Hermes schema.

Required behavior:
- endpoint: vLLM OpenAI-compatible server;
- served model: nemotron-base or promoted Mini Gibson adapter;
- inspect before edit;
- bounded SCOUT → PLAN → BUILD → TEST → DIAGNOSE/REPAIR → VERIFY flow;
- maximum three repairs;
- no success declaration before the Gibson Evidence Gate.
