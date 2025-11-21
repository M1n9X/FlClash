import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/cupertino.dart';

class Request {
  static Request? _instance;

  Request._internal();

  factory Request() => instance;

  static Request get instance {
    _instance ??= Request._internal();
    return _instance!;
  }

  late final Dio dio = _createDio();
  late final Dio _clashDio = _createClashDio();
  static const int _ipSourcesLimit = 4;
  final Duration _ipCacheDuration = const Duration(minutes: 1);
  Result<IpInfo?>? _cachedIpResult;
  DateTime? _cachedIpFetchedAt;
  Completer<Result<IpInfo?>>? _checkingIp;
  CancelToken? _checkingIpCancelToken;
  String? userAgent;

  Dio _createDio() {
    return Dio(BaseOptions(headers: {'User-Agent': browserUa}));
  }

  Dio _createClashDio() {
    final dio = Dio();
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );
    return dio;
  }

  Future<Response> getFileResponseForUrl(String url) async {
    final response = await _clashDio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    return response;
  }

  Future<Response> getTextResponseForUrl(String url) async {
    final response = await _clashDio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    return response;
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await dio.get<Uint8List>(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    final response = await dio.get(
      'https://api.github.com/repos/$repository/releases/latest',
      options: Options(responseType: ResponseType.json),
    );
    if (response.statusCode != 200) return null;
    final data = response.data as Map<String, dynamic>;
    final remoteVersion = data['tag_name'];
    final version = globalState.packageInfo.version;
    final hasUpdate =
        utils.compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
    if (!hasUpdate) return null;
    return data;
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  /// Clear IP cache and optionally cancel the ongoing shared request.
  void invalidateIpCache({bool cancelOngoing = true}) {
    _cachedIpResult = null;
    _cachedIpFetchedAt = null;
    if (cancelOngoing &&
        _checkingIpCancelToken != null &&
        !_checkingIpCancelToken!.isCancelled) {
      _checkingIpCancelToken!.cancel('invalidate');
    }
  }

  Future<Result<IpInfo?>> checkIp({
    CancelToken? cancelToken,
    bool forceRefresh = false,
  }) async {
    if (cancelToken?.isCancelled == true) {
      return Result.error('cancelled');
    }

    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedIpResult != null &&
        _cachedIpResult!.isSuccess &&
        _cachedIpFetchedAt != null &&
        now.difference(_cachedIpFetchedAt!) < _ipCacheDuration) {
      return _cachedIpResult!;
    }

    if (!forceRefresh &&
        _checkingIp != null &&
        !_checkingIp!.isCompleted &&
        _checkingIpCancelToken?.isCancelled != true) {
      return _waitWithCallerCancel(_checkingIp!.future, cancelToken);
    }

    final completer = Completer<Result<IpInfo?>>();
    _checkingIp = completer;
    _checkingIpCancelToken = CancelToken();

    final sources = _ipInfoSources.entries.take(_ipSourcesLimit).toList();
    if (sources.isEmpty) {
      final fallback = Result.success(null);
      _cacheIpResult(fallback);
      completer.complete(fallback);
    }

    if (sources.isNotEmpty) {
      var pending = sources.length;

      void handleFail() {
        pending -= 1;
        if (pending == 0 && !completer.isCompleted) {
          final fallback = Result.success(null);
          _cacheIpResult(fallback);
          completer.complete(fallback);
        }
      }

      for (final source in sources) {
        dio
            .get<Map<String, dynamic>>(
              source.key,
              cancelToken: _checkingIpCancelToken,
              options: Options(responseType: ResponseType.json),
            )
            .timeout(const Duration(seconds: 8))
            .then((res) {
              if (completer.isCompleted) return;
              if (res.statusCode == HttpStatus.ok && res.data != null) {
                final result = Result.success(source.value(res.data!));
                _cacheIpResult(result);
                completer.complete(result);
                return;
              }
              handleFail();
            })
            .catchError((e) {
              if (completer.isCompleted) return;
              if (e is DioException && e.type == DioExceptionType.cancel) {
                completer.complete(Result.error('cancelled'));
                return;
              }
              handleFail();
            });
      }
    }

    try {
          return await completer.future;
    } on Exception catch (e) {
      return Result.error(e.toString());
    } finally {
      _checkingIp = null;
      _checkingIpCancelToken = null;
    }
  }

  void _cacheIpResult(Result<IpInfo?> result) {
    if (result.isSuccess && result.data != null) {
      _cachedIpResult = result;
      _cachedIpFetchedAt = DateTime.now();
    }
  }

  Future<Result<IpInfo?>> _waitWithCallerCancel(
    Future<Result<IpInfo?>> future,
    CancelToken? cancelToken,
  ) {
    if (cancelToken == null) {
      return future;
    }
    if (cancelToken.isCancelled) {
      return Future.value(Result.error('cancelled'));
    }
    return Future.any([
      future,
      cancelToken.whenCancel.then((_) => Result.error('cancelled')),
    ]);
  }

  Future<bool> pingHelper() async {
    try {
      final response = await dio
          .get(
            'http://$localhost:$helperPort/ping',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      return (response.data as String) == globalState.coreSHA256;
    } catch (_) {
      return false;
    }
  }

  Future<bool> startCoreByHelper(String arg) async {
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/start',
            data: json.encode({'path': appPath.corePath, 'arg': arg}),
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<bool> stopCoreByHelper() async {
    try {
      final response = await dio
          .post(
            'http://$localhost:$helperPort/stop',
            options: Options(responseType: ResponseType.plain),
          )
          .timeout(const Duration(milliseconds: 2000));
      if (response.statusCode != HttpStatus.ok) {
        return false;
      }
      final data = response.data as String;
      return data.isEmpty;
    } catch (_) {
      return false;
    }
  }
}

Request get request => Request.instance;
