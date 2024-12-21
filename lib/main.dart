import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

import 'api_call.dart';
import 'text_pagination.dart';

void main() => runApp(const MainApp());

final _log = Logger("MainApp");

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  MainAppState createState() => MainAppState();
}

/// FrameVisionAppState mixin provides scaffolding for photo capture on (multi-) tap and a mechanism for processing each photo
/// in addition to the connection and application state management provided by SimpleFrameAppState
class MainAppState extends State<MainApp> with SimpleFrameAppState, FrameVisionAppState {

  // Custom API state
  String _apiEndpoint = '';
  final TextEditingController _apiEndpointTextFieldController = TextEditingController();
  final TextEditingController _promptTextFieldController = TextEditingController();

  // the image and metadata to show
  Image? _image;
  Uint8List? _uprightImageBytes;
  ImageMetadata? _imageMeta;
  bool _processing = false;

  // the response to show
  final List<String> _responseTextList = [];
  final TextPagination _pagination = TextPagination();

  MainAppState() {
    Logger.root.level = Level.FINE;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  void dispose() {
    _apiEndpointTextFieldController.dispose();
    _promptTextFieldController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // Frame connection and saved text field loading need to be performed asynchronously
    asyncInit();
  }

  Future<void> asyncInit() async {
    await _loadApiEndpoint();

    // kick off the connection to Frame and start the app if possible (unawaited)
    tryScanAndConnectAndStart(andRun: true);
  }

  Future<void> _loadApiEndpoint() async {
    final prefs = await SharedPreferences.getInstance();

    setState(() {
      _apiEndpoint = prefs.getString('api_endpoint') ?? '';
      _apiEndpointTextFieldController.text = _apiEndpoint;
    });
  }

  Future<void> _saveApiEndpoint() async {
    _apiEndpoint = _apiEndpointTextFieldController.text;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_endpoint', _apiEndpoint);
  }

  @override
  Future<void> onRun() async {
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: '3-Tap: take photo\n______________\n1-Tap: next page\n2-Tap: previous page'
      )
    );
  }

  @override
  Future<void> onCancel() async {
    _responseTextList.clear();
    _pagination.clear();
  }

  @override
  Future<void> onTap(int taps) async {
    switch (taps) {
      case 1:
        // next
        _pagination.nextPage();
        await frame!.sendMessage(
          TxPlainText(
            msgCode: 0x0a,
            text: _pagination.getCurrentPage().join('\n')
          )
        );
        break;
      case 2:
        // prev
        _pagination.previousPage();
        await frame!.sendMessage(
          TxPlainText(
            msgCode: 0x0a,
            text: _pagination.getCurrentPage().join('\n')
          )
        );
        break;
      case 3:
        // check if there's processing in progress already and drop the request if so
        if (!_processing) {
          _processing = true;
          // start new vision capture

          // show we're capturing on the Frame display
          await frame!.sendMessage(
            TxPlainText(
              msgCode: 0x0a,
              text: '\u{F0007}', // starry eyes emoji
              x: 285,
              y: 1,
              paletteOffset: 8,
            )
          );

          // asynchronously kick off the capture/processing pipeline
          capture().then(process);
        }
        break;
      default:
    }
  }

  /// The vision pipeline to run when a photo is captured
  FutureOr<void> process((Uint8List, ImageMetadata) photo) async {
    var imageData = photo.$1;
    var meta = photo.$2;

    try {
      img.Image? imgIm = img.decodeJpg(imageData);

      // if the photo is malformed, just bail out
      if (imgIm == null) {
        throw Exception('Error decoding photo');
      }

      // Frame camera is rotated 90 degrees clockwise,
      // so we need to make the image upright for image processing.
      imgIm = img.copyRotate(imgIm, angle: 270);
      _uprightImageBytes = img.encodeJpg(imgIm);

      // update UI with image and empty the text list
      setState(() {
        _image = Image.memory(_uprightImageBytes!, gaplessPlayback: true,);
        _imageMeta = meta;
        _responseTextList.clear();
      });

      // Perform vision processing pipeline on the current image
      // Initialize the service with the current _apiEndpoint
      final apiService = ApiService(endpointUrl: _apiEndpoint);

      // show we're calling the API
      await frame!.sendMessage(
        TxPlainText(
          msgCode: 0x0a,
          text: '\u{F0003}', // 3d shades emoji
          x: 285,
          y: 1,
          paletteOffset: 8,
        )
      );

      try {
        // Make the API call
        final response = await apiService.processImage(
          imageBytes: imageData,
        );

        // Handle the response
        _log.fine(() => 'Received text: $response');

        // show in ListView and paginate for Frame
        _handleResponseText(response);

      } catch (e) {
        // Error calling API (includes 404s as well as 500s)
        // separate "error in API" and "error calling API" if we can do so here
        _log.severe(e);
        await _handleResponseText(e.toString());
      }

      // indicate that we're done processing
      _processing = false;

    } catch (e) {
      // error processing image (or something else?)
      // TODO shouldn't happen often, but should I do this with if/then rather than try/catch
      String err = 'Error processing image: $e';
      _log.severe(err);
      await _handleResponseText(err);
      _processing = false;
    }
  }

  /// replace ListView text with the response,
  /// and also send the response to Frame for display
  Future<void> _handleResponseText(String text) async {
    _responseTextList.clear();
    _pagination.clear();
    List<String> splitText = text.split('\n');

    // add to the ListView
    _responseTextList.addAll(splitText);

    // prepare for display on Frame (accommodating its line width)
    for (var line in splitText) {
      _pagination.appendLine(line);
    }

    // put the response on Frame's display
    await frame!.sendMessage(
      TxPlainText(
        msgCode: 0x0a,
        text: _pagination.getCurrentPage().join('\n')
      )
    );

    // redraw the UI
    setState(() {});
  }

  /// Use the platform Share mechanism to share the image and the generated text
  static void _shareImage(Uint8List? jpegBytes, String text) async {
    if (jpegBytes != null) {
      try {
        // Share the image bytes as a JPEG file
        await Share.shareXFiles(
          [XFile.fromData(jpegBytes, mimeType: 'image/jpeg', name: 'image.jpg')],
          text: text,
        );
      }
      catch (e) {
        _log.severe('Error preparing image for sharing: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'API - Frame Vision',
      theme: ThemeData.dark(),
      home: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: const Text('API - Frame Vision'),
          actions: [getBatteryWidget()]
        ),
        drawer: getCameraDrawer(),
        body: Column(
          children: [
            Row(
              children: [
                Expanded(child: TextField(
                  controller: _apiEndpointTextFieldController,
                  decoration: const InputDecoration(
                    hintText: 'E.g. http://192.168.0.5:8000/process'
                  ),
                )),
                ElevatedButton(onPressed: _saveApiEndpoint, child: const Text('Save'))
              ],
            ),
            Expanded(
            child: GestureDetector(
              onTap: () {
                if (_uprightImageBytes != null) {
                  _shareImage(_uprightImageBytes, _responseTextList.join('\n'));
                }
              },
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _image,
                    ),
                  ),
                  if (_imageMeta != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(children: [
                          _imageMeta!,
                          const Divider()
                        ]),
                      ),
                    ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16.0,
                          ),
                          child: Text(_responseTextList[index]),
                        );
                      },
                      childCount: _responseTextList.length,
                    ),
                  ),
                  // This ensures the list can grow dynamically
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Container(), // Empty container to allow scrolling
                  ),
                ],
              ),
            ),
          ),
          ],
        ),
        floatingActionButton: getFloatingActionButtonWidget(const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }
}
