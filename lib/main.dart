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
    // Avoid auto-fetching until user explicitly requests it.
    stationsFuture = Future.value([]);
  }

  void _incrementCounter() {
    setState(() {
      _counter++;
    });
  }

  void _refreshStations() {
    setState(() {
      stationsFuture = fetchGasStations(promptForLocationPopup: true);
    });
  }

  Future<Position> _getCurrentPosition({
    required bool promptForGpsSettings,
  }) async {
    if (promptForGpsSettings && mounted) {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        final shouldRequest = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Location Permission Required'),
            content: const Text(
              'This app needs location access to find nearby gas stations. Allow location access?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        );

        if (shouldRequest == true) {
          await Geolocator.requestPermission();
        }
      }
    }

    var serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled && promptForGpsSettings && mounted) {
      final openSettings = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Enable Location Services'),
          content: const Text(
            'Please enable your device GPS/location services to locate nearby gas stations.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
      if (openSettings == true) {
        await Geolocator.openLocationSettings();
        serviceEnabled = await Geolocator.isLocationServiceEnabled();
      }
    }

    if (!serviceEnabled) {
      throw Exception(
        'Location services are disabled. Please enable GPS and retry.',
      );
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw Exception(
        'Location permission denied. Please grant location permission.',
      );
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Permission Required'),
            content: const Text(
              'Location permission is permanently denied. Open app settings to restore it.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      await Geolocator.openAppSettings();
      throw Exception(
        'Location permission permanently denied. Open app settings and grant permission.',
      );
    }

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

    return Geolocator.getCurrentPosition(locationSettings: locationSettings);
  }

  Future<List<LatLng>> _fetchStationsFromOverpass(
    Position position, {
    int radius = 5000,
  }) async {
    final query =
        '''
      [out:json][timeout:25];
      node["amenity"="fuel"](around:$radius, ${position.latitude}, ${position.longitude});
      out center;
    ''';

    final endpoints = [
      'https://overpass-api.de/api/interpreter',
      'https://lz4.overpass-api.de/api/interpreter',
      'https://overpass.kumi.systems/api/interpreter',
      'https://overpass.openstreetmap.fr/api/interpreter',
    ];

    const backoff = [1, 2, 4, 8];
    const maxAttempts = 4;

    for (final endpoint in endpoints) {
      for (var attempt = 0; attempt < maxAttempts; attempt++) {
        final response = await http.post(
          Uri.parse(endpoint),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {'data': query},
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data == null || data['elements'] == null) {
            return [];
          }

          return (data['elements'] as List)
              .where((e) => e['lat'] != null && e['lon'] != null)
              .map((e) => LatLng(e['lat'], e['lon']))
              .toList();
        }

        final bodyLower = response.body.toLowerCase();
        final isRateLimited =
            response.statusCode == 429 ||
            response.statusCode == 504 ||
            bodyLower.contains('rate_limited') ||
            bodyLower.contains('dispatcher_client::request_read_and_idx') ||
            bodyLower.contains('quota');

        if (!isRateLimited) {
          throw Exception(
            'Overpass API returned ${response.statusCode}: ${response.body}',
          );
        }

        if (attempt < maxAttempts - 1) {
          final wait = Duration(seconds: backoff[attempt]);
          debugPrint(
            'Overpass rate limited on $endpoint attempt ${attempt + 1}, waiting ${wait.inSeconds}s',
          );
          await Future.delayed(wait);
        } else {
          debugPrint(
            'Endpoint $endpoint failed after $maxAttempts attempts, switching endpoint.',
          );
        }
      }
    }

    throw Exception(
      'Overpass endpoints are busy or rate-limited. Please try again later.',
    );
  }

  Future<List<LatLng>> _fetchStationsWithFallback(Position position) async {
    var stations = await _fetchStationsFromOverpass(position, radius: 5000);
    if (stations.isNotEmpty) return stations;
    stations = await _fetchStationsFromOverpass(position, radius: 10000);
    return stations;
  }

  Future<List<LatLng>> fetchGasStations({
    bool promptForLocationPopup = false,
  }) async {
    try {
      final position = await _getCurrentPosition(
        promptForGpsSettings: promptForLocationPopup,
      );
      final stations = await _fetchStationsWithFallback(position);
      if (stations.isEmpty) {
        throw Exception(
          'No gas stations found nearby. Try a different location or wait a moment and retry.',
        );
      }
      return stations;
    } catch (error) {
      debugPrint('Failed to get location/stations: $error');
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
