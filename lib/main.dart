import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_frame_app/frame_vision_app.dart';
import 'package:simple_frame_app/simple_frame_app.dart';
import 'package:simple_frame_app/tx/plain_text.dart';

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

    // Frame connection and Gemini model initialization need to be performed asynchronously
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
        frame!.sendMessage(
          TxPlainText(
            msgCode: 0x0a,
            text: _pagination.getCurrentPage().join('\n')
          )
        );
        break;
      case 2:
        // prev
        _pagination.previousPage();
        frame!.sendMessage(
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
    _responseTextList.clear();

    try {
      // NOTE: Frame camera is rotated 90 degrees clockwise,
      // so we need to make it upright for Gemini image processing.
      img.Image? imgIm = img.decodeJpg(imageData);
      if (imgIm == null) {
        // if the photo is malformed, just bail out
        throw Exception('Error decoding photo');
      }

      // perform the rotation and re-encode as JPEG
      imgIm = img.copyRotate(imgIm, angle: 270);
      _uprightImageBytes = img.encodeJpg(imgIm);

      // update Widget UI
      // For the widget we rotate it upon display with a transform,
      // not changing the source image
      Image im = Image.memory(imageData, gaplessPlayback: true,);

      setState(() {
        _image = im;
        _imageMeta = meta;
      });

      // Perform vision processing pipeline on the current image, i.e. multimodal API call

      // TODO make API call and return response
      // final content = [
      //   Content.data('image/jpeg', _uprightImageBytes!),
      //   Content.text(_prompt)];

      // this call will throw an exception if the api_key is not valid
      // var responseStream = null;

      // _pagination.clear();

      // // show in ListView and paginate for Frame
      // await for (final response in responseStream) {
      //   _log.fine(response.text);
      //   _appendResponseText(response.text!);
      //   setState(() {});
      //   await frame!.sendMessage(
      //     TxPlainText(
      //       msgCode: 0x0a,
      //       text: _pagination.getCurrentPage().join('\n')
      //     )
      //   );
      // }


      // indicate that we're done processing
      _processing = false;

    } catch (e) {
      String err = 'Error processing photo: $e';
      _log.fine(err);
      setState(() {
        _responseTextList.add(err);
      });
      _processing = false;
      // TODO rethrow;?
    }
  }

  /// generated text contains newlines when it wants them, otherwise append strings
  /// directly
  void _appendResponseText(String text) {
    List<String> splitText = text.split('\n');

    if (_responseTextList.isEmpty) {
      _responseTextList.addAll(splitText);

      for (var line in splitText) {
        _pagination.appendLine(line);
      }
    }
    else {
      if (splitText.isNotEmpty) {
        // append the first line of splitText to the last string in list
        String updatedLastLine = _responseTextList[_responseTextList.length-1] + splitText[0];
        _responseTextList[_responseTextList.length-1] = updatedLastLine;
        _pagination.updateLastLine(updatedLastLine);

        // append all the other lines from splitText to list
        _responseTextList.addAll(splitText.skip(1));
        for (var line in splitText.skip(1)) {
          _pagination.appendLine(line);
        }
      }
      // else nothing to do
    }
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
                Expanded(child: TextField(controller: _apiEndpointTextFieldController, decoration: const InputDecoration(hintText: 'Enter API Endpoint'),)),
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
                      child: Transform(
                        alignment: Alignment.center,
                        // images are rotated 90 degrees clockwise from the Frame
                        // so reverse that for display
                        transform: Matrix4.rotationZ(-pi*0.5),
                        child: _image,
                      ),
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
