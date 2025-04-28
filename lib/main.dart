// ignore_for_file: avoid_print, constant_identifier_names

import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:loader_overlay/loader_overlay.dart';

import 'dart:io' show Platform;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Forcer l'orientation portrait
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Demander les permissions BLE
  if (Platform.isAndroid) {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TRR 2025',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const CarControlScreen(),
    );
  }
}

class CarControlScreen extends StatefulWidget {
  const CarControlScreen({super.key});

  @override
  State<CarControlScreen> createState() => _CarControlScreenState();
}

class _CarControlScreenState extends State<CarControlScreen> {
  //final BluetoothService _bluetoothService = BluetoothService();

  late BluetoothDevice device;
  BluetoothCharacteristic? controlCharacteristic;
  BluetoothCharacteristic? sensorCharacteristic;

  // Constants
  static const double minAngle = -30.0;
  static const double maxAngle = 30.0;
  static const double minSpeed = 0.0;
  static const double maxSpeed = 255.0;

  static const String SERVICE_UUID = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  static const String CONTROL_CHARACTERISTIC_UUID =
      "beb5483e-36e1-4688-b7f5-ea07361b26a8";
  static const String SENSOR_CHARACTERISTIC_UUID =
      "beb5483e-36e1-4688-b7f5-ea07361b26a9";

  // State variables
  bool isBTON = false;
  bool isConnected = false;
  bool isScanning = false;
  bool isAutoMode = false;
  double motor1Speed = 0.0;
  double motor2Speed = 0.0;
  double direction = 0.0;
  int leftDistance = 0;
  int rightDistance = 0;
  bool isFinishLineDetected = false;
  List<ScanResult> scanResults = [];
  bool motorsLocked = false;
  bool isGoMode = true; // Au démarrage, le bouton est en mode GO (vert)
  bool isBackwardMode = false; // Nouvelle variable pour le mode marche arrière
  double autoMotorPower =
      50.0; // Nouvelle variable pour la puissance des moteurs en mode auto
  DateTime _lastDirectionUpdateTime =
      DateTime.now(); // For throttling direction updates
  DateTime _lastMotor1UpdateTime =
      DateTime.now(); // For throttling motor1 updates
  DateTime _lastMotor2UpdateTime =
      DateTime.now(); // For throttling motor2 updates

  // Liste pour stocker les logs des capteurs
  final List<String> sensorLogs = [];
  static const int maxLogs = 100; // Nombre maximum de logs à conserver

  // Paramètres PID
  double kp = 0.01;
  double ki = 0.0;
  double kd = 0.0;

  // Constantes pour les limites des paramètres PID
  static const double minKp = 0.0;
  static const double maxKp = 0.3;
  static const double minKi = 0.0;
  static const double maxKi = 0.05;
  static const double minKd = 0.0;
  static const double maxKd = 0.05;

  @override
  void initState() {
    requestBluetoothPermission();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      startCheckBTActivation();
    });
    super.initState();
  }

  void requestBluetoothPermission() async {
    //await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void startCheckBTActivation() async {
    try {
      FlutterBluePlus.adapterState.listen((BluetoothAdapterState state) {
        if (state == BluetoothAdapterState.on) {
          setState(() {
            isBTON = true;
          });
        } else {
          setState(() {
            isBTON = false;
          });
        }
      });
    } catch (e) {
      print(e);
    }
  }

  Future<bool> _checkPermissions() async {
    if (!Platform.isAndroid) return true;

    // Demander d'abord la localisation
    var locationStatus = await Permission.location.request();
    if (!locationStatus.isGranted) {
      _showError(
          'La permission de localisation est nécessaire pour le scan Bluetooth');
      return false;
    }

    // Demander ensuite les permissions Bluetooth
    Map<Permission, PermissionStatus> statuses = await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ].request();

    bool allGranted = true;
    String deniedPermissions = '';

    statuses.forEach((permission, status) {
      if (!status.isGranted) {
        allGranted = false;
        deniedPermissions += '${permission.toString()}, ';
      }
    });

    if (!allGranted) {
      _showError(
          'Permissions Bluetooth manquantes: $deniedPermissions\nVeuillez les activer dans les paramètres');
      return false;
    }

    return true;
  }

  Future<void> _startScan() async {
    // Vérifier les permissions d'abord
    if (!await _checkPermissions()) {
      return;
    }

    // Vérifier si le Bluetooth est activé
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      _showError('Veuillez activer le Bluetooth');
      return;
    }

    setState(() {
      isScanning = true;
      scanResults.clear();
      context.loaderOverlay.show();
    });
    print("Recherche en cours...");

    // Variable pour suivre si TRR_CAR a été trouvé
    bool trrCarFound = false;
    // Déclarer la variable subscription en dehors du bloc
    StreamSubscription<List<ScanResult>>? subscription;

    try {
      // S'assurer que tout scan précédent est arrêté
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
      }

      //Scanning subscription declaration
      subscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          if (trrCarFound) return; // Ignorer si déjà trouvé

          setState(() {
            scanResults = results;
          });

          // Rechercher TRR_CAR dans les résultats
          for (ScanResult r in results) {
            print(
                'Appareil trouvé: ${r.device.remoteId} "${r.advertisementData.advName}" (RSSI: ${r.rssi})');

            // Vérifier si c'est notre appareil TRR_CAR
            String name = r.advertisementData.advName.isNotEmpty
                ? r.advertisementData.advName
                : r.device.platformName;

            if (name.contains("TRR_CAR")) {
              print("TRR_CAR trouvé! Arrêt du scan et connexion...");

              // Marquer comme trouvé
              trrCarFound = true;

              // Mettre à jour l'état du scan
              setState(() {
                isScanning = false;
              });

              // Arrêter le scan
              FlutterBluePlus.stopScan();

              // Se connecter automatiquement
              _connectToDevice(r.device);
              return;
            }
          }
        },
        onError: (e) {
          print("Erreur pendant le scan: $e");
          _showError('Erreur pendant le scan: $e');
          setState(() {
            isScanning = false;
            context.loaderOverlay.hide();
          });
        },
      );

      // Start scanning
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 4),
        withKeywords: ["TRR_CAR"],
        androidUsesFineLocation: true,
      );

      // Attendre que le scan soit terminé (si TRR_CAR n'est pas trouvé)
      await Future.delayed(const Duration(seconds: 4));

      // Cleanup
      subscription.cancel();
      if (await FlutterBluePlus.isScanning.first) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      print("Erreur de démarrage du scan: $e");
      _showError('Erreur de démarrage du scan: $e');
    } finally {
      if (!trrCarFound) {
        setState(() {
          isScanning = false;
          context.loaderOverlay.hide();
        });
      }
    }
  }

  Future<void> _connectToDevice(BluetoothDevice deviceToConnect) async {
    setState(() {
      context.loaderOverlay.show();
      isScanning = false;
    });

    try {
      device = deviceToConnect;

      var deviceStateStream = device.connectionState.listen(
        (BluetoothConnectionState event) async {
          if (event == BluetoothConnectionState.connected) {
            setState(() {
              isConnected = true;
              isScanning = false;
            });

            print("Connecté, découverte des services...");
            List<BluetoothService>? services = await device.discoverServices();
            for (BluetoothService s in services) {
              if (s.uuid.toString() == SERVICE_UUID) {
                var characteristics = s.characteristics;

                for (BluetoothCharacteristic c in characteristics) {
                  if (c.uuid.toString() == CONTROL_CHARACTERISTIC_UUID) {
                    controlCharacteristic = c;
                    print("Caractéristique de contrôle connectée");
                  }
                  if (c.uuid.toString() == SENSOR_CHARACTERISTIC_UUID) {
                    sensorCharacteristic = c;
                    print("Caractéristique de capteur connectée");
                    await c.setNotifyValue(true);
                    c.lastValueStream.listen(_handleSensorData);
                  }
                }
              }
            }
          } else if (event == BluetoothConnectionState.disconnected) {
            setState(() {
              isConnected = false;
              isScanning = false;
              isAutoMode = false;
              isGoMode = true;
              isBackwardMode = false;
              motor1Speed = 0.0;
              motor2Speed = 0.0;
              direction = 0.0;
              leftDistance = 0;
              rightDistance = 0;
            });
          }
        },
      );

      device.cancelWhenDisconnected(deviceStateStream,
          delayed: true, next: true);

      print("Connexion à l'appareil...");
      await device.connect(
        timeout: const Duration(seconds: 10),
        autoConnect: false,
      );
    } catch (e) {
      print("Erreur de connexion: $e");
      _showError('Erreur de connexion: $e');
      setState(() {
        isConnected = false;
        isScanning = false;
      });
    } finally {
      setState(() {
        context.loaderOverlay.hide();
        isScanning = false;
      });
    }
  }

  Future<void> _disconnect() async {
    try {
      await device.disconnect();
      setState(() {
        isConnected = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Déconnecté'),
        ),
      );
    } catch (e) {
      _showError('Erreur de déconnexion: $e');
    }
  }

  void _handleSensorData(List<int> data) {
    if (data.length >= 4) {
      setState(() {
        leftDistance = data[0] | (data[1] << 8);
        rightDistance = data[2] | (data[3] << 8);
        isFinishLineDetected = data.length > 4 ? data[4] == 1 : false;

        // Ajouter un nouveau log avec timestamp
        String timestamp = DateTime.now().toString().split('.')[0];
        String logEntry =
            "[$timestamp] Gauche: $leftDistance mm, Droite: $rightDistance mm, Ligne d'arrivée: ${isFinishLineDetected ? "Détectée" : "Non détectée"}";

        // Ajouter le nouveau log au début de la liste
        sensorLogs.insert(0, logEntry);

        // Limiter le nombre de logs
        if (sensorLogs.length > maxLogs) {
          sensorLogs.removeLast();
        }
      });
    }
  }

  @override
  void dispose() {
    //_bluetoothService.disconnect();
    super.dispose();
  }

  // Méthode pour obtenir la couleur en fonction de la distance
  Color _getDistanceColor(int distance) {
    if (distance < 50) {
      return Colors.red; // Très proche - danger
    } else if (distance < 200) {
      return Colors.orange; // Proche - attention
    } else if (distance < 500) {
      return Colors.yellow; // Distance moyenne
    } else {
      return Colors.green; // Distance sûre
    }
  }

  // Calcule la position horizontale de la voiture en fonction des distances
  double _calculateCarPosition(int leftDistance, int rightDistance) {
    // Largeur du conteneur de visualisation
    double containerWidth = MediaQuery.of(context).size.width -
        32; // Largeur du conteneur (moins padding)
    double carWidth = 40; // Largeur de l'icône de voiture en pixels
    double availableWidth = containerWidth - carWidth;

    // Dimensions réelles
    const double trackWidth = 1000; // Largeur de la piste en mm (1 mètre)
    //const double carRealWidth =  150; // Largeur réelle de la voiture en mm (15 cm)

    // Si les deux capteurs mesurent la même distance, la voiture est au milieu
    if (leftDistance > 0 &&
        rightDistance > 0 &&
        (leftDistance - rightDistance).abs() < 50) {
      // Tolérance de 50mm
      return (containerWidth - carWidth) / 2; // Centre exact
    }

    // Calcul basé sur la différence entre les distances gauche et droite
    // Si les distances sont égales, la voiture est au centre
    // Si la distance gauche est plus grande, la voiture est plus à droite
    // Si la distance droite est plus grande, la voiture est plus à gauche
    if (leftDistance > 0 && rightDistance > 0) {
      // Calculer la position relative basée sur la différence
      double totalSpace = leftDistance.toDouble() + rightDistance.toDouble();
      double normalizedPosition = leftDistance.toDouble() / totalSpace;

      // Ajuster pour que 0.5 (distances égales) corresponde au centre
      return availableWidth * normalizedPosition;
    }

    // Si un seul capteur fonctionne, utiliser sa valeur
    if (leftDistance > 0) {
      // Position basée uniquement sur la distance gauche
      // Limiter à la plage 0-trackWidth pour éviter les valeurs aberrantes
      double clampedDistance = leftDistance.toDouble().clamp(0.0, trackWidth);
      double normalizedPosition = clampedDistance / trackWidth;
      return availableWidth * normalizedPosition;
    } else if (rightDistance > 0) {
      // Position basée uniquement sur la distance droite
      // Inverser car plus la distance droite est grande, plus la voiture est à gauche
      double clampedDistance = rightDistance.toDouble().clamp(0.0, trackWidth);
      double normalizedPosition = 1.0 - (clampedDistance / trackWidth);
      return availableWidth * normalizedPosition;
    }

    // Par défaut, centrer la voiture
    return availableWidth / 2;
  }

  @override
  Widget build(BuildContext context) {
    return LoaderOverlay(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('TRR 2025 🏎️'),
          actions: [
            // Connection status
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: Center(
                child: Row(
                  children: [
                    Text(
                      isScanning
                          ? 'Recherche...'
                          : isConnected
                              ? 'Connecté'
                              : 'Non connecté',
                      style: TextStyle(
                        fontSize: 14,
                        color: isConnected ? Colors.green : Colors.grey,
                      ),
                    ),
                    if (isScanning)
                      const Padding(
                        padding: EdgeInsets.only(left: 4.0),
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Scan button
            if (!isConnected)
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () async {
                  await _startScan();
                },
              ),
            // Connect/Disconnect button
            if (isConnected)
              IconButton(
                icon: const Icon(Icons.bluetooth_connected),
                color: Colors.blue,
                onPressed: _disconnect,
              ),
          ],
        ),
        body: Column(
          children: [
            // Scan results
            if (!isConnected && !isScanning)
              Expanded(
                flex: 1,
                child: scanResults.isNotEmpty
                    ? ListView.builder(
                        itemCount: scanResults.length,
                        itemBuilder: (context, index) {
                          final result = scanResults[index];
                          final device = result.device;
                          final name =
                              result.advertisementData.advName.isNotEmpty
                                  ? result.advertisementData.advName
                                  : device.platformName.isNotEmpty
                                      ? device.platformName
                                      : device.remoteId.toString();
                          return ListTile(
                            title: Text(name),
                            subtitle: Text('RSSI: ${result.rssi}'),
                            trailing: ElevatedButton(
                              child: const Text('Connecter'),
                              onPressed: () => _connectToDevice(device),
                            ),
                          );
                        },
                      )
                    : Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Aucun appareil trouvé',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 20),
                            ElevatedButton(
                              onPressed: _startScan,
                              child: const Text('Scanner',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  )),
                            ),
                            const SizedBox(height: 20),
                            const Text(
                              'Astuces :',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 20),
                              child: Text(
                                '1. Vérifiez que l\'ESP32 est allumé\n'
                                '2. Activez le Bluetooth\n'
                                '3. Activez la localisation dans les paramètres Android\n'
                                '4. Accordez toutes les permissions\n'
                                '5. Redémarrez l\'ESP32 si nécessaire',
                                textAlign: TextAlign.left,
                              ),
                            ),
                          ],
                        ),
                      ),
              ),

            // Main control interface (when connected)
            if (isConnected)
              Expanded(
                child: AbsorbPointer(
                  absorbing: !isConnected,
                  child: Opacity(
                    opacity: isConnected ? 1.0 : 0.5,
                    child: SingleChildScrollView(
                      child: Column(
                        children: [
                          // Controls section (top)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16.0, vertical: 8.0),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                // Mode switch and Stop button in a row
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceEvenly,
                                  children: [
                                    // Mode switch
                                    Container(
                                      padding: const EdgeInsets.all(8),
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Row(
                                        children: [
                                          Text(
                                            'Manuel',
                                            style: TextStyle(
                                              fontWeight: !isAutoMode
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                              color: !isAutoMode
                                                  ? Colors.blueGrey
                                                  : Colors.grey,
                                            ),
                                          ),
                                          Switch(
                                            value: isAutoMode,
                                            activeColor: Colors.green,
                                            onChanged: !isGoMode
                                                ? null // Désactiver le switch si isGoMode est true
                                                : (value) {
                                                    // Si on était en mode ARRÊT (isGoMode = false),
                                                    // envoyer la commande d'arrêt et repasser en mode GO
                                                    if (!isGoMode) {
                                                      controlCharacteristic
                                                          ?.write(utf8
                                                              .encode("E1"));
                                                      setState(() {
                                                        isGoMode =
                                                            true; // Repasser en mode GO
                                                      });
                                                    }

                                                    setState(() {
                                                      isAutoMode = value;
                                                      motor1Speed = 0;
                                                      motor2Speed = 0;
                                                    });

                                                    // Envoyer la commande de changement de mode
                                                    controlCharacteristic
                                                        ?.write(utf8.encode(
                                                            "A${value ? 1 : 0}"));
                                                  },
                                          ),
                                          Text(
                                            'Auto',
                                            style: TextStyle(
                                              fontWeight: isAutoMode
                                                  ? FontWeight.bold
                                                  : FontWeight.normal,
                                              color: isAutoMode
                                                  ? Colors.green
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    // GO/STOP button
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        if (isGoMode) {
                                          // Si on est en mode GO, envoyer la commande de démarrage
                                          // et passer en mode ARRÊT
                                          controlCharacteristic
                                              ?.write(utf8.encode("G1"));
                                          setState(() {
                                            isGoMode =
                                                false; // Passer en mode ARRÊT
                                          });
                                        } else {
                                          // Si on est en mode ARRÊT, envoyer la commande d'arrêt
                                          // et repasser en mode GO
                                          controlCharacteristic
                                              ?.write(utf8.encode("E1"));

                                          // Réinitialiser les valeurs des moteurs en mode manuel
                                          if (!isAutoMode) {
                                            setState(() {
                                              motor1Speed = 0;
                                              motor2Speed = 0;
                                            });
                                          }

                                          setState(() {
                                            isGoMode =
                                                true; // Repasser en mode GO
                                          });
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: isGoMode
                                            ? Colors.green
                                            : Colors.red,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 12),
                                      ),
                                      icon: Icon(isGoMode
                                          ? Icons.play_arrow
                                          : Icons.stop),
                                      label: Text(isGoMode ? 'GO' : 'ARRÊT'),
                                    ),
                                  ],
                                ),

                                // Afficher les contrôles manuels ou les paramètres PID selon le mode
                                if (!isAutoMode) ...[
                                  // Motor 1 control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Moteur 1',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            '${motor1Speed.toInt()}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: motor1Speed > 0
                                                  ? Colors.green
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.green,
                                          thumbColor: Colors.green,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: motor1Speed,
                                          min: minSpeed,
                                          max: maxSpeed,
                                          onChanged: (value) {
                                            setState(() {
                                              motor1Speed = value;
                                              // Si les moteurs sont verrouillés, synchroniser le moteur 2
                                              if (motorsLocked) {
                                                motor2Speed = value;
                                              }
                                            });

                                            // Throttle the BLE commands to avoid overloading
                                            final now = DateTime.now();
                                            if (now
                                                    .difference(
                                                        _lastMotor1UpdateTime)
                                                    .inMilliseconds >
                                                100) {
                                              controlCharacteristic?.write(
                                                  utf8.encode(
                                                      "M1${value.toInt()}"));
                                              _lastMotor1UpdateTime = now;

                                              // Si les moteurs sont verrouillés, envoyer aussi la commande au moteur 2
                                              if (motorsLocked) {
                                                controlCharacteristic?.write(
                                                    utf8.encode(
                                                        "M2${value.toInt()}"));
                                                _lastMotor2UpdateTime = now;
                                              }
                                            }
                                          },
                                          onChangeEnd: (value) {
                                            // Always send a final update when slider stops
                                            controlCharacteristic?.write(utf8
                                                .encode("M1${value.toInt()}"));
                                            _lastMotor1UpdateTime =
                                                DateTime.now();

                                            // Si les moteurs sont verrouillés, envoyer aussi la commande finale au moteur 2
                                            if (motorsLocked) {
                                              controlCharacteristic?.write(
                                                  utf8.encode(
                                                      "M2${value.toInt()}"));
                                              _lastMotor2UpdateTime =
                                                  DateTime.now();
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Bouton de verrouillage des moteurs et mode marche arrière
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      // Bouton de verrouillage des moteurs
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            motorsLocked = !motorsLocked;
                                            // Si on active le verrouillage, synchroniser les moteurs sur la valeur du moteur 1
                                            if (motorsLocked) {
                                              motor2Speed = motor1Speed;
                                            }
                                          });
                                        },
                                        child: Icon(
                                          motorsLocked
                                              ? Icons.link
                                              : Icons.link_off,
                                          color: motorsLocked
                                              ? Colors.green
                                              : Colors.grey,
                                          size: 25,
                                        ),
                                      ),
                                      const SizedBox(width: 20),
                                      // Bouton mode marche arrière
                                      GestureDetector(
                                        onTap: () {
                                          setState(() {
                                            isBackwardMode = !isBackwardMode;
                                          });
                                          // Envoyer la commande de changement de mode marche arrière
                                          controlCharacteristic?.write(
                                              utf8.encode(
                                                  "B${isBackwardMode ? 1 : 0}"));
                                        },
                                        child: Icon(
                                          isBackwardMode
                                              ? Icons.arrow_back
                                              : Icons.arrow_forward,
                                          color: isBackwardMode
                                              ? Colors.orange
                                              : Colors.grey,
                                          size: 25,
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Motor 2 control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Moteur 2',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            '${motor2Speed.toInt()}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: motor2Speed > 0
                                                  ? Colors.green
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.green,
                                          thumbColor: Colors.green,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: motor2Speed,
                                          min: minSpeed,
                                          max: maxSpeed,
                                          onChanged: (value) {
                                            setState(() {
                                              motor2Speed = value;
                                              // Si les moteurs sont verrouillés, synchroniser le moteur 1
                                              if (motorsLocked) {
                                                motor1Speed = value;
                                              }
                                            });

                                            // Throttle the BLE commands to avoid overloading
                                            final now = DateTime.now();
                                            if (now
                                                    .difference(
                                                        _lastMotor2UpdateTime)
                                                    .inMilliseconds >
                                                100) {
                                              controlCharacteristic?.write(
                                                  utf8.encode(
                                                      "M2${value.toInt()}"));
                                              _lastMotor2UpdateTime = now;

                                              // Si les moteurs sont verrouillés, envoyer aussi la commande au moteur 1
                                              if (motorsLocked) {
                                                controlCharacteristic?.write(
                                                    utf8.encode(
                                                        "M1${value.toInt()}"));
                                                _lastMotor1UpdateTime = now;
                                              }
                                            }
                                          },
                                          onChangeEnd: (value) {
                                            // Always send a final update when slider stops
                                            controlCharacteristic?.write(utf8
                                                .encode("M2${value.toInt()}"));
                                            _lastMotor2UpdateTime =
                                                DateTime.now();

                                            // Si les moteurs sont verrouillés, envoyer aussi la commande finale au moteur 1
                                            if (motorsLocked) {
                                              controlCharacteristic?.write(
                                                  utf8.encode(
                                                      "M1${value.toInt()}"));
                                              _lastMotor1UpdateTime =
                                                  DateTime.now();
                                            }
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Direction control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Direction',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            '${direction.toInt()}°',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: direction != 0
                                                  ? (direction < 0
                                                      ? Colors.blue
                                                      : Colors.orange)
                                                  : Colors.grey,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.blue,
                                          thumbColor: Colors.blue,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: direction,
                                          min: minAngle,
                                          max: maxAngle,
                                          onChanged: (value) {
                                            setState(() {
                                              direction = value;
                                            });

                                            // Throttle the BLE commands to avoid overloading
                                            final now = DateTime.now();
                                            if (now
                                                    .difference(
                                                        _lastDirectionUpdateTime)
                                                    .inMilliseconds >
                                                100) {
                                              // 100ms throttle
                                              controlCharacteristic?.write(utf8
                                                  .encode("D${value.toInt()}"));
                                              _lastDirectionUpdateTime = now;
                                            }
                                          },
                                          onChangeEnd: (value) {
                                            // Always send a final update when slider stops to ensure the last position is sent
                                            controlCharacteristic?.write(utf8
                                                .encode("D${value.toInt()}"));
                                            _lastDirectionUpdateTime =
                                                DateTime.now();
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ] else ...[
                                  // Paramètres PID en mode automatique
                                  // Kp control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Kp (Proportionnel)',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            kp.toStringAsFixed(3),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.blue,
                                          thumbColor: Colors.blue,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: kp,
                                          min: minKp,
                                          max: maxKp,
                                          divisions: 300,
                                          onChanged: (value) {
                                            setState(() {
                                              kp = value;
                                            });
                                          },
                                          onChangeEnd: (value) {
                                            controlCharacteristic?.write(
                                                utf8.encode(
                                                    "P${value.toStringAsFixed(3)}"));
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Ki control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Ki (Intégral)',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            ki.toStringAsFixed(3),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.green,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.green,
                                          thumbColor: Colors.green,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: ki,
                                          min: minKi,
                                          max: maxKi,
                                          divisions: 50,
                                          onChanged: (value) {
                                            setState(() {
                                              ki = value;
                                            });
                                          },
                                          onChangeEnd: (value) {
                                            controlCharacteristic?.write(
                                                utf8.encode(
                                                    "I${value.toStringAsFixed(3)}"));
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                  // Kd control
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Kd (Dérivé)',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            kd.toStringAsFixed(3),
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.orange,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.orange,
                                          thumbColor: Colors.orange,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: kd,
                                          min: minKd,
                                          max: maxKd,
                                          divisions: 50,
                                          onChanged: (value) {
                                            setState(() {
                                              kd = value;
                                            });
                                          },
                                          onChangeEnd: (value) {
                                            controlCharacteristic?.write(
                                                utf8.encode(
                                                    "K${value.toStringAsFixed(3)}"));
                                          },
                                        ),
                                      ),
                                    ],
                                  ),

                                  // Motor power control in auto mode
                                  Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Puissance Moteurs',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          Text(
                                            '${autoMotorPower.toInt()}%',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue,
                                            ),
                                          ),
                                        ],
                                      ),
                                      SliderTheme(
                                        data: SliderTheme.of(context).copyWith(
                                          activeTrackColor: Colors.blue,
                                          thumbColor: Colors.blue,
                                          thumbShape:
                                              const RoundSliderThumbShape(
                                                  enabledThumbRadius: 12),
                                        ),
                                        child: Slider(
                                          value: autoMotorPower,
                                          min: 0,
                                          max: 100,
                                          divisions: 100,
                                          onChanged: (value) {
                                            setState(() {
                                              autoMotorPower = value;
                                            });
                                          },
                                          onChangeEnd: (value) {
                                            // Envoyer la commande de puissance des moteurs
                                            controlCharacteristic?.write(utf8
                                                .encode("T${value.toInt()}"));
                                          },
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Sensor data section (bottom)
                          Container(
                            width: double.infinity,
                            color: Theme.of(context).colorScheme.surface,
                            padding: const EdgeInsets.all(10.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Données Capteurs',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Distance sensors with visual indicators
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        children: [
                                          const Text('Distance Gauche'),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$leftDistance mm',
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          LinearProgressIndicator(
                                            value: leftDistance > 850
                                                ? 1.0
                                                : leftDistance / 850,
                                            color:
                                                _getDistanceColor(leftDistance),
                                            backgroundColor:
                                                Colors.grey.shade800,
                                            minHeight: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 20),
                                    Expanded(
                                      child: Column(
                                        children: [
                                          const Text('Distance Droite'),
                                          const SizedBox(height: 2),
                                          Text(
                                            '$rightDistance mm',
                                            style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          LinearProgressIndicator(
                                            value: rightDistance > 850
                                                ? 1.0
                                                : rightDistance / 850,
                                            color: _getDistanceColor(
                                                rightDistance),
                                            backgroundColor:
                                                Colors.grey.shade800,
                                            minHeight: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 10),
                                // Finish line detector
                                Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Text(
                                      'Ligne d\'arrivée : ',
                                      style: TextStyle(fontSize: 14),
                                    ),
                                    Container(
                                      width: 16,
                                      height: 16,
                                      decoration: BoxDecoration(
                                        color: isFinishLineDetected
                                            ? Colors.green
                                            : Colors.red,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      isFinishLineDetected
                                          ? 'Détectée'
                                          : 'Non détectée',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: isFinishLineDetected
                                            ? Colors.green
                                            : Colors.red,
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 10),
                                // Logs des capteurs
                                const Text(
                                  'Logs des capteurs :',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Container(
                                  height: 150,
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade900,
                                    borderRadius: BorderRadius.circular(8),
                                    border:
                                        Border.all(color: Colors.grey.shade800),
                                  ),
                                  child: ListView.builder(
                                    reverse: true,
                                    itemCount: sensorLogs.length,
                                    itemBuilder: (context, index) {
                                      return Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0,
                                          vertical: 2.0,
                                        ),
                                        child: Text(
                                          sensorLogs[index],
                                          style: const TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12,
                                            fontFamily: 'monospace',
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ConnectingOverlay extends StatelessWidget {
  const ConnectingOverlay({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20.0),
              child: CircularProgressIndicator(
                color: Color(0xff2D4263),
                strokeWidth: 5,
              ),
            ),
            SizedBox(height: 20),
            Text(
              'Connexion en cours...',
              style: TextStyle(fontSize: 25),
            ),
          ],
        ),
      );
}

// Classe pour dessiner une ligne pointillée au centre de la piste
class DashedLinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke;

    const dashHeight = 10;
    const dashSpace = 5;
    double startY = 0;
    final centerX = size.width / 2;

    // Dessiner une ligne pointillée verticale au centre
    while (startY < size.height) {
      canvas.drawLine(
        Offset(centerX, startY),
        Offset(centerX, startY + dashHeight),
        paint,
      );
      startY += dashHeight + dashSpace;
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
