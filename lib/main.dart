import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:geolocator/geolocator.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});
  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  int _counter = 0;
  late Future<List<LatLng>> stationsFuture;

  @override
  void initState() {
    super.initState();
    stationsFuture = fetchGasStations();
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  void _refreshStations() {
    setState(() {
      // Re-assigning the future triggers the FutureBuilder to run again
      stationsFuture = fetchGasStations();
    });
  }

  Future<void> _ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception(
        'Location services are disabled. Please enable GPS and retry.',
      );
    }

    var permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception(
          'Location permissions are denied. Please grant permission and retry.',
        );
      }
    }

    if (permission == LocationPermission.deniedForever) {
      throw Exception(
        'Location permissions are permanently denied. Please enable them in settings.',
      );
    }
  }

  Future<List<LatLng>> fetchGasStations() async {
    try {
      await _ensureLocationPermission();
      //get location thru gps
      // Define the settings (usually high or best for navigation)
      const LocationSettings locationSettings = LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100, // Optional: updates only if moved 100 meters
      );

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );
      // request to overpass API (with rate-limit retry support)
      final query =
          """
        [out:json];
        node["amenity"="fuel"](around:5000, ${position.latitude}, ${position.longitude});
        out;
      """;

      http.Response response;
      int attempt = 0;
      const int maxAttempts = 3;
      const backoff = [1, 2, 5];

      while (true) {
        response = await http.post(
          Uri.parse('https://overpass-api.de/api/interpreter'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'data': query},
        );

        final bodyLower = response.body.toLowerCase();

        if (response.statusCode == 200) {
          break;
        }

        final isRateLimited =
            response.statusCode == 429 ||
            response.statusCode == 504 ||
            bodyLower.contains('rate_limited') ||
            bodyLower.contains('dispatcher_client::request_read_and_idx') ||
            bodyLower.contains('quota');

        if (isRateLimited && attempt < maxAttempts - 1) {
          final wait = Duration(seconds: backoff[attempt]);
          debugPrint(
            'Overpass rate limited on attempt ${attempt + 1}, waiting ${wait.inSeconds}s',
          );
          await Future.delayed(wait);
          attempt++;
          continue;
        }

        throw Exception(
          'Overpass API returned ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body);
      if (data == null || data['elements'] == null) {
        debugPrint('Overpass API returned unexpected data: ${response.body}');
        return [];
      }

      final stations = (data['elements'] as List)
          .where((e) => e['lat'] != null && e['lon'] != null)
          .map((e) => LatLng(e['lat'], e['lon']))
          .toList();

      return stations;
    } catch (error) {
      debugPrint('Failed to get location: $error');
      // Forward the error to FutureBuilder so UI can show a message
      return Future.error(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('US heard you have oil'),
            const Text('Map'),
            Container(
              height: 200,
              width: 200,
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: FutureBuilder<List<LatLng>>(
                  future: stationsFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return Center(child: CircularProgressIndicator());
                    }

                    if (snapshot.hasError) {
                      final errorText =
                          snapshot.error?.toString() ?? 'Unknown error';
                      return Center(
                        child: Text(
                          'Error: $errorText',
                          textAlign: TextAlign.center,
                        ),
                      );
                    }

                    if (!snapshot.hasData || snapshot.data!.isEmpty) {
                      return Center(child: Text("No stations found"));
                    }

                    final stations = snapshot.data!;
                    return FlutterMap(
                      options: MapOptions(
                        keepAlive: true,
                        initialCenter: stations.isNotEmpty
                            ? stations.first
                            : LatLng(14.5995, 120.9842),
                        initialZoom: 14,
                      ),
                      children: [
                        TileLayer(
                          urlTemplate:
                              'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                          userAgentPackageName: 'com.leon.oil_watch',
                          additionalOptions: {
                            'User-Agent': 'oil_watch (com.leon.oil_watch)',
                          },
                        ),
                        MarkerLayer(
                          markers: stations.map((pos) {
                            return Marker(
                              point: pos,
                              width: 30,
                              height: 30,
                              child: Icon(
                                Icons.local_gas_station,
                                color: Colors.red,
                              ),
                            );
                          }).toList(),
                        ),
                        RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution(
                              '© OpenStreetMap contributors',
                              onTap: () => launchUrl(
                                Uri.parse(
                                  'https://www.openstreetmap.org/copyright',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            TextButton(
              onPressed: _refreshStations,
              child: const Text('Gas Stations Near Me'),
            ),
            const Text('git check'),
            const Text('You have pushed the button this many times:'),
            Text(
              '$_counter',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _incrementCounter,
        tooltip: 'Increment',
        child: const Icon(Icons.add),
      ),
    );
  }
}
