#!/bin/bash

# build script version 1.0
#

echo "# Building fodder_marine"

echo "  Step 1: Remove old builds"
rm build/*
echo "  Step 2: Build game"
odin build fodder_marine.odin -file > build/fodder_marine
echo "  Step 3: Remove root executable"
rm fodder_marine
