#include <Arduino.h>
#include <ArduinoJson.h>

// Measured against a reference meter before use. Do not treat nominal 5 V as calibration.
#ifndef ADC_REFERENCE_V
#define ADC_REFERENCE_V 5.0f
#endif

char input[512];
size_t used = 0;
String lastId;
String lastResponse;

void execute(const char *line) {
  JsonDocument command;
  if (deserializeJson(command, line)) return;
  String id = command["command_id"] | "";
  if (id.length() == 0 || id.length() > 64) return;
  if (id == lastId) { Serial.println(lastResponse); return; }
  String point = command["point_id"] | "";
  int pin = point == "TP1" ? A0 : point == "TP2" ? A1 : point == "TP3" ? A2 : -1;
  int count = command["sample_count"] | 0;
  String action = command["action"] | "";
  JsonDocument result;
  result["command_id"] = id;
  result["point_id"] = point;
  result["status"] = "precondition_failed";
  result["sample_count"] = 0;
  result["unit"] = action == "read_digital" ? "boolean" : "V";
  if (String(command["protocol_version"] | "") == "1" &&
      String(command["action"] | "") == "read_voltage" && pin >= 0 && count >= 1 && count <= 100) {
    analogRead(pin); // discard first sample after channel switch
    long total = 0;
    bool saturated = false;
    for (int i = 0; i < count; ++i) {
      int raw = analogRead(pin);
      saturated |= raw >= 1023;
      total += raw;
      delay(2);
    }
    result["status"] = saturated ? "out_of_range" : "ok";
    result["sample_count"] = count;
    if (!saturated) result["value"] = total * ADC_REFERENCE_V / (count * 1023.0f);
  }
  if (String(command["protocol_version"] | "") == "1" &&
      action == "read_digital" && pin >= 0 && count >= 1 && count <= 100) {
    // Read-only input. No pull-up, writes, inferred voltage threshold or actuation.
    pinMode(pin, INPUT);
    bool state = digitalRead(pin) == HIGH;
    bool stable = true;
    for (int i = 0; i < count; ++i) {
      stable &= (digitalRead(pin) == HIGH) == state;
      delay(2);
    }
    result["status"] = stable ? "ok" : "out_of_range";
    result["sample_count"] = count;
    if (stable) result["value"] = state;
  }
  lastId = id;
  lastResponse = "";
  serializeJson(result, lastResponse);
  Serial.println(lastResponse);
}

void setup() { Serial.begin(115200); }
void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') { input[used] = '\0'; execute(input); used = 0; }
    else if (used < sizeof(input) - 1) input[used++] = c;
    else used = 0;
  }
}
