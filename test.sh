#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p .build/t
cp tests.swift .build/t/main.swift
swiftc -O Core.swift .build/t/main.swift -o .build/tests
.build/tests
