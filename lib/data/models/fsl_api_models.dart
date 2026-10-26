/// Raw DTOs for Salesforce Field Service (FSL) Visualforce Remoting responses.
class FslRemotingMethodToken {
  const FslRemotingMethodToken({
    required this.name,
    required this.csrf,
    required this.authorization,
    this.ns = 'FSL',
    this.ver = 50.0,
  });

  final String name;
  final String csrf;
  final String authorization;
  final String ns;
  final double ver;
}

class FslRemotingContext {
  const FslRemotingContext({
    required this.vid,
    required this.methods,
    required this.fetchedAtEpochMs,
  });

  final String vid;
  final Map<String, FslRemotingMethodToken> methods;
  final int fetchedAtEpochMs;

  FslRemotingMethodToken? tokenFor(String methodName) => methods[methodName];
}

/// Unwraps Salesforce Visualforce Remoting `{"s": n, "v": value}` wrappers.
dynamic unwrapSfValue(dynamic value) {
  if (value is Map &&
      value.length == 2 &&
      value.containsKey('s') &&
      value.containsKey('v')) {
    return unwrapSfValue(value['v']);
  }
  return value;
}

/// Resolves all Salesforce JSRemoting object serialization wrappers (`{"s": id, "v": val}`)
/// and back-references (`{"r": id}`) across an entire RPC response tree.
dynamic resolveSfRemotingRefs(dynamic root) {
  final byId = <int, dynamic>{};

  dynamic pass1(dynamic node) {
    if (node is Map) {
      if (node.length == 2 && node.containsKey('s') && node.containsKey('v')) {
        final s = node['s'];
        final resolved = pass1(node['v']);
        if (s is int) {
          byId[s] = resolved;
        }
        return resolved;
      }
      final out = <String, dynamic>{};
      node.forEach((k, v) {
        out[k.toString()] = pass1(v);
      });
      return out;
    } else if (node is List) {
      return node.map(pass1).toList();
    }
    return node;
  }

  dynamic pass2(dynamic node, [int depth = 0]) {
    if (depth > 12) return node;
    if (node is Map) {
      if (node.length == 1 && node.containsKey('r')) {
        final r = node['r'];
        if (r is int && byId.containsKey(r)) {
          return pass2(byId[r], depth + 1);
        }
        return null;
      }
      final out = <String, dynamic>{};
      node.forEach((k, v) {
        out[k.toString()] = pass2(v, depth + 1);
      });
      return out;
    } else if (node is List) {
      return node.map((e) => pass2(e, depth + 1)).toList();
    }
    return node;
  }

  return pass2(pass1(root));
}

class FslServiceAppointmentDto {
  const FslServiceAppointmentDto({
    required this.id,
    required this.appointmentNumber,
    required this.status,
    this.statusCategory,
    this.callId,
    this.callType,
    this.resourceId,
    this.resourceName,
    this.resourceContractorName,
    this.workTypeName,
    this.parentRecordId,
    this.parentTowSaId,
    this.relatedService1Id,
    this.relatedService2Id,
    this.dependencyType,
    this.schedStartWallMs,
    this.schedEndWallMs,
    this.actualStartWallMs,
    this.lastModifiedEpochMs,
    this.spottedEpochMs,
    this.ganttColorHex,
    this.ganttLabel,
    this.memberName,
    this.memberPhone,
    this.benefitLevel,
    this.memberVehicle,
    this.street,
    this.city,
    this.latitude,
    this.longitude,
    this.isDeleted = false,
    this.isPinned = false,
  });

  factory FslServiceAppointmentDto.fromJson(Map<String, dynamic> rawJson) {
    final json = unwrapSfValue(rawJson);
    if (json is! Map) {
      return const FslServiceAppointmentDto(
        id: '',
        appointmentNumber: '',
        status: 'Scheduled',
      );
    }
    final rawFields = unwrapSfValue(json['Fields']);
    final fields = (rawFields is Map) ? rawFields : json;

    String? coerceText(dynamic v) {
      final u = unwrapSfValue(v);
      if (u is String) {
        final trimmed = u.trim();
        return trimmed.isEmpty ? null : trimmed;
      }
      if (u is Map) {
        final name = unwrapSfValue(u['Name'] ?? u['name']);
        if (name is String && name.trim().isNotEmpty) {
          return name.trim();
        }
      }
      return null;
    }

    String? pickStr(List<String> keys) {
      for (final k in keys) {
        final v = coerceText(fields[k]) ?? coerceText(json[k]);
        if (v != null && v.isNotEmpty) {
          return v;
        }
      }
      return null;
    }

    int? pickInt(List<String> keys) {
      for (final k in keys) {
        final v = unwrapSfValue(fields[k] ?? json[k]);
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) {
          final parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    double? pickDouble(List<String> keys) {
      for (final k in keys) {
        final v = unwrapSfValue(fields[k] ?? json[k]);
        if (v is double) return v;
        if (v is num) return v.toDouble();
        if (v is String) {
          final parsed = double.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    final id = pickStr(['Id', 'id']) ?? '';
    final apptNum =
        pickStr(['AppointmentNumber', 'Name', 'appointmentNumber']) ?? id;
    final rawCallId = pickStr([
      'D3_Call_ID__c',
      'ERS_Dispatch_Call_ID__c',
      'ERS_Call_ID__c',
      'Call_ID__c',
      'GanttLabel__c',
    ]);
    final callId = rawCallId ?? apptNum.replaceFirst(RegExp(r'^SA-0*'), '');

    final parentFields = unwrapSfValue(json['ParentFields']);
    final parentId =
        pickStr(['ParentRecordId', 'AccountId']) ??
        (parentFields is Map ? coerceText(parentFields['Id']) : null);

    final territory =
        pickStr([
          'ServiceTerritory.Name',
          'ResourceContractorName',
          'ServiceTerritoryName',
          'TerritoryName',
        ]) ??
        coerceText(fields['ServiceTerritory']) ??
        coerceText(json['ServiceTerritory']) ??
        (parentFields is Map
            ? coerceText(parentFields['ServiceTerritory'])
            : null);

    return FslServiceAppointmentDto(
      id: id,
      appointmentNumber: apptNum,
      status: pickStr(['Status', 'status']) ?? 'Scheduled',
      statusCategory: pickStr(['StatusCategory']),
      callId: callId,
      callType: pickStr(['WO_Call_Type__c', 'Call_Type__c']),
      resourceId: pickStr([
        'Resource',
        'Service_Resource__c',
        'ResourceId',
        'AssignedResource',
        'FSL__Assigned_Resource__c',
        'resource',
      ]),
      resourceName: pickStr([
        'ResourceName',
        'Service_Resource__r',
      ]),
      resourceContractorName: territory,
      workTypeName: pickStr([
        'WorkType',
        'WorkTypeName',
        'ERS_Work_Type_Name__c',
        'WorkTypeId',
        'WO_Call_Type__c',
      ]),
      parentRecordId: parentId,
      parentTowSaId: pickStr(['ERS_Parent_Tow_SA__c']),
      relatedService1Id: pickStr([
        'relatedService1',
        'Related_Service__c',
        'Related_Service_1',
        'FSL__Related_Service__c',
      ]),
      relatedService2Id: pickStr(['Related_Service_2']),
      dependencyType: pickStr([
        'relationshipType',
        'FSL__Time_Dependency__c',
        'TimeDependency',
      ]),
      schedStartWallMs: pickInt(['SchedStartTime', 'schedStart']),
      schedEndWallMs: pickInt(['SchedEndTime', 'schedEnd']),
      actualStartWallMs: pickInt(['ActualStartTime', 'actualStart']),
      lastModifiedEpochMs: pickInt(['LastModifiedDate', 'lastModified']),
      spottedEpochMs: pickInt(['CreatedDate', 'ERS_Spotted_Time__c']),
      ganttColorHex: pickStr([
        'GanttColor__c',
        'FSL__GanttColor__c',
        'ganttColor',
      ]),
      ganttLabel: pickStr([
        'FSL_Member_Vehicle_Name__c',
        'FSL__GanttLabel__c',
        'Subject',
        'Description',
      ]),
      memberName: pickStr(['Contact', 'Contact.Name', 'Member_Name__c']),
      memberPhone: pickStr(['Phone_Number__c', 'ERS_Phone_Number__c']),
      benefitLevel: pickStr([
        'Member_Benefit_Level__c',
        'ERS_Benefit_Level__c',
      ]),
      memberVehicle: pickStr([
        'FSL_Member_Vehicle_Name__c',
        'FSL__GanttLabel__c',
      ]),
      street: pickStr(['Street', 'FSL_Street_City__c', 'Address']),
      city: pickStr(['City']),
      latitude: pickDouble(['Latitude', 'latitude']),
      longitude: pickDouble(['Longitude', 'longitude']),
      isDeleted:
          unwrapSfValue(fields['IsDeleted'] ?? json['IsDeleted']) == true,
      isPinned:
          unwrapSfValue(fields['FSL__Pinned__c'] ?? json['Pinned']) == true,
    );
  }

  final String id;
  final String appointmentNumber;
  final String status;
  final String? statusCategory;
  final String? callId;
  final String? callType;
  final String? resourceId;
  final String? resourceName;
  final String? resourceContractorName;
  final String? workTypeName;
  final String? parentRecordId;
  final String? parentTowSaId;
  final String? relatedService1Id;
  final String? relatedService2Id;
  final String? dependencyType;
  final int? schedStartWallMs;
  final int? schedEndWallMs;
  final int? actualStartWallMs;
  final int? lastModifiedEpochMs;
  final int? spottedEpochMs;
  final String? ganttColorHex;
  final String? ganttLabel;
  final String? memberName;
  final String? memberPhone;
  final String? benefitLevel;
  final String? memberVehicle;
  final String? street;
  final String? city;
  final double? latitude;
  final double? longitude;
  final bool isDeleted;
  final bool isPinned;
}

class FslResourceDto {
  const FslResourceDto({
    required this.id,
    required this.name,
    this.territoryName,
    this.latitude,
    this.longitude,
    this.lastLocationWallMs,
    this.isActive = true,
  });

  factory FslResourceDto.fromJson(Map<String, dynamic> rawJson) {
    final json = unwrapSfValue(rawJson);
    if (json is! Map) {
      return const FslResourceDto(id: '', name: '');
    }
    final rawFields = unwrapSfValue(json['Fields']);
    final fields = (rawFields is Map) ? rawFields : json;

    String? pickStr(List<String> keys) {
      for (final k in keys) {
        final v = unwrapSfValue(fields[k] ?? json[k]);
        if (v is Map) {
          final nested = unwrapSfValue(v['Name'] ?? v['name']);
          if (nested != null && nested.toString().trim().isNotEmpty) {
            return nested.toString().trim();
          }
        }
        if (v != null && v.toString().trim().isNotEmpty) {
          return v.toString().trim();
        }
      }
      return null;
    }

    double? pickDouble(List<String> keys) {
      for (final k in keys) {
        final v = unwrapSfValue(fields[k] ?? json[k]);
        if (v is double) return v;
        if (v is num) return v.toDouble();
        if (v is String) {
          final parsed = double.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    int? pickInt(List<String> keys) {
      for (final k in keys) {
        final v = unwrapSfValue(fields[k] ?? json[k]);
        if (v is int) return v;
        if (v is num) return v.toInt();
        if (v is String) {
          final parsed = int.tryParse(v);
          if (parsed != null) return parsed;
        }
      }
      return null;
    }

    return FslResourceDto(
      id: pickStr(['Id', 'id']) ?? '',
      name: pickStr(['Name', 'name', 'ResourceName']) ?? '',
      territoryName: pickStr([
        'ServiceTerritory.Name',
        'ServiceTerritoryName',
        'TerritoryName',
      ]),
      latitude: pickDouble(['LastKnownLatitude', 'latitude']),
      longitude: pickDouble(['LastKnownLongitude', 'longitude']),
      lastLocationWallMs: pickInt([
        'LastKnownLocationDate',
        'lastLocationDate',
      ]),
      isActive:
          unwrapSfValue(fields['IsActive'] ?? json['isActive'] ?? true) == true,
    );
  }

  final String id;
  final String name;
  final String? territoryName;
  final double? latitude;
  final double? longitude;
  final int? lastLocationWallMs;
  final bool isActive;
}
