import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:math' show Random;
import 'package:flutter/material.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf;
import 'package:path/path.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:media_store_plus/media_store_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'database.dart';
import '../models.dart';
import '../constants.dart';
import 'discover.dart';

///Class for all Recieve jobs
///
///Available methods are [listen] and [stopListening]
class Receive {
  ///Saved files in current session
  ///
  ///All element must manually removed from list after displaying in the ui
  static List<DbFile> files = [];
  static final _ms = MediaStore();
  static late Directory _tempDir;
  static late int _code;
  static HttpServer? _server;
  static bool _isBusy = false;

  ///Starts listening for discovery and recieving file(s).
  ///Handles one connection at once. If another device tires to match,
  ///sends `400 Bad request` as response
  ///
  ///[port] listened for incoming connections. Should not set except testing or
  ///other devices will require manual port setting.
  ///
  ///If [downloadAnimC] is set, progress will be sent to it.
  ///
  ///If [saveToTemp] is `true`, files will be saved to temp directory. It's useful for
  ///testing because don't need for storage permissions
  ///
  ///If [useDb] is `true`, file informations will be saved to sqflite database.
  ///Don't needed to open the database manually.
  ///Must set to `false` for prevent database usage.
  ///
  ///Returns the code generated for discovery. Other devices should select this code for
  ///connecting to this device
  static Future<int> listen(
      {int? port,
      bool useDb = true,
      bool saveToTemp = false,
      AnimationController? downloadAnimC}) async {
    if ((Platform.isAndroid || Platform.isIOS)) {
      //These platforms needs storage permissions (only tested on Android)
      final perm = await Permission.storage.request();
      if (!perm.isGranted) throw "Permission denied";
    }

    final ip = await Discover.getMyIp();
    _code = Random().nextInt(8888) + 1111;
    MediaStore.appFolder = Constants.saveFolder;
    _tempDir = await getTemporaryDirectory();
    _isBusy = false;

    for (var port = Constants.minPort; port <= Constants.maxPort; port++) {
      try {
        _server = await shelf.serve(
            (request) => _requestMethod(request,
                useDb: useDb,
                saveToTemp: saveToTemp,
                downloadAnimC: downloadAnimC),
            ip,
            port,
            poweredByHeader: null);
        break;
      } on SocketException catch (_) {
        if (port < Constants.maxPort) {
          continue;
        } else {
          rethrow;
        }
      }
    }
    log("Listening for new file with port: ${_server!.port}, code: $_code",
        name: "Receive");
    return _code;
  }

  static Future<Response> _requestMethod(Request request,
      {required bool useDb,
      required bool saveToTemp,
      AnimationController? downloadAnimC}) async {
    if (_isBusy) {
      //Deny new connections if busy
      log("Connection denied, because busy", name: "Receive server");
      return Response.forbidden(null);
    }
    if (request.method == "GET") {
      //Response to discovery requests
      log("Discovery request recieved, returned code $_code",
          name: "Receive server");
      return Response.ok(
          jsonEncode({"message": Constants.meeting, "code": _code}));
    } else if (request.method == "POST") {
      //Reciving file
      log("Reciving file...", name: "Receive server");
      try {
        _isBusy = true;
        final stream = MimeMultipartTransformer(
                MediaType.parse(request.headers['content-type']!)
                    .parameters["boundary"]!)
            .bind(request.read());

        final db = DatabaseManager();
        if (useDb) {
          await db.open();
        }
        await for (var mime in stream) {
          String filename =
              HeaderValue.parse(mime.headers['content-disposition']!)
                  .parameters["filename"]!;
          late File file;
          if ((Platform.isLinux || Platform.isWindows)) {
            //Saving to downloads because these platforms don't require any permission
            final dir = Directory(join(
                (await getDownloadsDirectory())!.path, Constants.saveFolder));
            dir.createSync();

            file = File(join(dir.path, filename));
            file = _generateFileName(file, dir);
          } else {
            //Saving to the temp folder for mediastore or testing
            file = File(join(_tempDir.path, filename));
            file = _generateFileName(file, _tempDir);
          }
          final totalBytesPer100 = request.contentLength! / 100;
          int downloadedBytesto100 = 0;
          await for (var bytes in mime) {
            file.writeAsBytesSync(bytes, mode: FileMode.writeOnlyAppend);

            downloadedBytesto100 += bytes.length;
            if (downloadedBytesto100 >= totalBytesPer100) {
              downloadAnimC?.value += 0.01;
              downloadedBytesto100 - totalBytesPer100;
            }
          }
          final mimeType = lookupMimeType(file.path);
          final bool isSaved;
          if ((Platform.isLinux || Platform.isWindows) || saveToTemp) {
            //Skipping Media Store confirmation for desktop platforms or saving to temp folder
            isSaved = true;
          } else {
            //Using Media Store for mobile platforms
            isSaved = await _ms.saveFile(
                tempFilePath: file.path,
                dirType: DirType.download,
                dirName: DirName.download);
          }
          if (isSaved) {
            //Setting file type
            String? type;
            if (mimeType != null) {
              if (mimeType.startsWith("image/")) {
                type = "image";
              } else if (mimeType.startsWith("audio/")) {
                type = "audio";
              } else if (mimeType.startsWith("video/")) {
                type = "video";
              }
            }
            final dbFile = DbFile(
                name: filename,
                time: DateTime.now(),
                fileStatus: DbFileStatus.download,
                fileType: type == null
                    ? null
                    : DbFileType.values
                        .singleWhere((element) => element.name == type),
                path: file.path);
            files.add(dbFile);
            if (useDb) {
              await db.insert(dbFile);
            }
          }
        }
        if (useDb) {
          await db.close();
        }
        return Response.ok(null);
      } catch (_) {
        rethrow;
      } finally {
        //File downloaded successfully or failed. Resetting progess for both cases.
        downloadAnimC?.value = 1;

        //Open for new connections
        _isBusy = false;
      }
    }
    //Request method neither POST or GET
    log("Invalid request recieved", name: "Receive server");
    return Response.badRequest();
  }

  ///Ensures a file with same name not exists.
  ///
  ///It may rename files as file.exe to file (1).exe
  static File _generateFileName(File file, Directory dir) {
    for (var i = 1; file.existsSync(); i++) {
      final name = basenameWithoutExtension(file.path);
      final exten = extension(file.path);
      file = File(join(dir.path, "$name ($i)$exten"));
    }
    return file;
  }

  ///Closes the listening server.
  ///
  ///Is is safe to call before [listen] or after [listen] .
  static Future<void>? stopListening() => _server?.close();
}
