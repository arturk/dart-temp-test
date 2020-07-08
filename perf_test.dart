import 'dart:convert';
import 'dart:io';

import 'package:flutter_driver/flutter_driver.dart';
import 'package:flutter_driver/src/driver/timeline.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm_service;
import 'package:vm_service/vm_service_io.dart';

class FunctionDescription {
  String name;
  String fromClass;
  String hits;
}

void main() {
  FlutterDriver driver;
  vm_service.VmService vms;
  vm_service.Isolate isolate;
  int testCounter = 0;
  int startTime, endTime;
  int pauseTime = 0;
  List<Map<String, List<int>>> userTags;

  Future<T> runWithoutTimeMeasurement<T>(Function func, {List<dynamic> args, Map<Symbol, dynamic> kwargs}) async {
    int localStartTime = DateTime.now().microsecondsSinceEpoch;
    final T res = await Function.apply(func, args, kwargs);
    pauseTime += DateTime.now().microsecondsSinceEpoch - localStartTime;
    return res;
  }

  void setUserTag(String tagName, int startTime) {
    userTags.add({
      tagName: [startTime, DateTime.now().microsecondsSinceEpoch]
    });
  }

  setUpAll(() async {
    String vmUrl = Platform.environment['VM_SERVICE_URL'].replaceFirst(new RegExp(r'http:'), 'ws:') + "ws";
    driver = await FlutterDriver.connect(printCommunication: true).timeout(Duration(seconds: 30));
    await driver.waitUntilNoTransientCallbacks();
    vms = await vmServiceConnectUri(vmUrl);
    String isolateName = (await driver.appIsolate.loadRunnable()).name;
    isolate = await vms.getIsolate((await vms.getVM()).isolates.firstWhere((isol) => isol.name == isolateName).id);
    expect((await vms.setFlag("profiler", "true")), isA<vm_service.Success>());
  });

  tearDownAll(() async {
    if (driver != null) {
      await driver.close();
    }
  });

  tearDown(() async {
    if (driver != null) {
      endTime = DateTime.now().microsecondsSinceEpoch;
      vm_service.CpuSamples cpuSamples = await vms.getCpuSamples(isolate.id, 0, ~0);
      cpuSamples.samples.forEach((sample) {
        userTags.forEach((tag) => (sample.timestamp > tag.values.first[0] && sample.timestamp < tag.values.first[1])
            ? sample.userTag = tag.keys.first
            : null);
      });
      vm_service.AllocationProfile alProf = await vms.getAllocationProfile(isolate.id);
      Timeline timeline = await driver.stopTracingAndDownloadTimeline();
      await TimelineSummary.summarize(timeline).writeTimelineToFile("test_$testCounter", pretty: true);
      await File("$testOutputsDirectory/source_reports_$testCounter.json").writeAsString(
          jsonEncode((await vms.getSourceReport(isolate.id, [vm_service.SourceReportKind.kCoverage])).json));
      await File("$testOutputsDirectory/cpu_samples_$testCounter.json").writeAsString(jsonEncode(cpuSamples.json));
      await File("$testOutputsDirectory/mem_samples_$testCounter.json").writeAsString(jsonEncode(alProf.json));

      Map<String, dynamic> customPerformanceReport = Map<String, dynamic>();
      customPerformanceReport["testTime"] = endTime - startTime - pauseTime;
      customPerformanceReport["usedFunctions"] = Map<String, dynamic>();
      cpuSamples.functions.forEach((f) {
        if (f.exclusiveTicks > 0) {
          var jdata = f.toJson()["function"];
          if (jdata["type"] == "@Function") {
            List<String> hierarchyClassesList = List();
            bool nextOwnerExists = true;
            Map<String, dynamic> ownerJson = jdata["owner"];
            while (nextOwnerExists) {
              hierarchyClassesList.add(ownerJson["name"]);
              ownerJson.containsKey("owner") ? ownerJson = ownerJson["owner"] : nextOwnerExists = false;
            }
            customPerformanceReport["usedFunctions"][hierarchyClassesList.join("::") + "::" + jdata["name"]] = {
              "occurences": f.exclusiveTicks,
              "file": f.toJson().containsKey("resolvedUrl") ? f.toJson()["resolvedUrl"] : null
            };
          }
        }
      });
      await File("$testOutputsDirectory/custom_perf_report_$testCounter.json")
          .writeAsString(jsonEncode(customPerformanceReport));
      assert(cpuSamples.samples.length > 0); // getCpuSamples has 0 samples for me
    } else
      throw Exception("Something went wrong during the test");
  });

  setUp(() async {
    testCounter++;
    userTags = List<Map<String, List<int>>>();
    await driver.clearTimeline();
    await driver.startTracing(streams: [
      TimelineStream.dart,
      TimelineStream.api,
      TimelineStream.vm,
      TimelineStream.compiler,
      TimelineStream.isolate
    ]);
    startTime = DateTime.now().microsecondsSinceEpoch;
  });

  group('Profiling flow', () {
    test("Do smth", () async {
      int locStartTime = DateTime.now().microsecondsSinceEpoch;
      sleep(Duration(seconds:10)); // Do something with your app here manually
      setUserTag("My Custom Tag For This Activity", locStartTime);
    });
  }, tags: 'Performance');
}
