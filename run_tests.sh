#!/bin/bash

flutter pub get

adb install app-debug.apk
sleep 2

adb shell am start -n com.example.quizapp/.MainActivity
sleep 5

url=$(adb logcat -d | grep -o -E "Observatory listening on (.*)" | tail -1 | cut -d" " -f 4)
port=$(echo $url | cut -d: -f3 | cut -d/ -f1)

echo $url
export VM_SERVICE_URL=$url

adb forward tcp:$port tcp:$port
flutter packages pub run test perf_test.dart
