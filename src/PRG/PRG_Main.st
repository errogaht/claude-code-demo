(*
    PRG_Main - Главная программа каскадного управления котлами

    Описание:
    Пример использования FB_CascadeControl для управления 4 паровыми котлами.
    Программа обеспечивает связь между панелью оператора ШУО, датчиками
    и контроллерами котлов ШУПК1-ШУПК4.

    Привязка к задаче:
    - Рекомендуется вызывать в циклической задаче с периодом 100мс
*)
PROGRAM PRG_Main
VAR
    (* === Экземпляр функционального блока каскада === *)
    fbCascade           : FB_CascadeControl;

    (* === Входы от панели оператора ШУО === *)
    HMI_CascadeEnable   : BOOL;             // Кнопка "Включить" каскадное управление
    HMI_CascadeDisable  : BOOL;             // Кнопка "Отключить" каскадное управление

    (* Уставки от оператора *)
    HMI_PressureSetpoint        : REAL := 0.8;      // Уставка давления, МПа
    HMI_PowerConnectThreshold   : REAL := 3.5;      // Порог мощности для подключения, МВт
    HMI_PowerDisconnectThreshold: REAL := 1.5;      // Порог мощности для отключения, МВт
    HMI_ConnectDelay            : TIME := T#60S;    // Задержка подключения
    HMI_DisconnectDelay         : TIME := T#60S;    // Задержка отключения
    HMI_StabilizationTime       : TIME := T#120S;   // Время стабилизации
    HMI_ReservePowerSetpoint    : REAL := 2.5;      // Уставка мощности резервных, МВт
    HMI_PowerRampRate           : REAL := 0.1;      // Скорость изменения мощности, МВт/с

    (* Приоритеты котлов от оператора *)
    HMI_Boiler1Priority : INT := 1;         // Приоритет котла 1 (0-4)
    HMI_Boiler2Priority : INT := 2;         // Приоритет котла 2 (0-4)
    HMI_Boiler3Priority : INT := 3;         // Приоритет котла 3 (0-4)
    HMI_Boiler4Priority : INT := 4;         // Приоритет котла 4 (0-4)

    (* === Входы от датчика давления в общем паропроводе === *)
    AI_CommonPressure   : REAL;             // Давление в общем паропроводе, МПа (от датчика)

    (* === Данные от контроллеров котлов ШУПК1-ШУПК4 === *)
    (* Обычно эти данные приходят по сети (Modbus, Profinet, etc.) *)
    SHUPK1_Online       : BOOL;             // ШУПК1 на связи
    SHUPK1_RemoteMode   : BOOL;             // ШУПК1 дистанционный режим
    SHUPK1_Fault        : BOOL;             // ШУПК1 неисправность
    SHUPK1_ActualPower  : REAL;             // ШУПК1 текущая мощность
    SHUPK1_Running      : BOOL;             // ШУПК1 работает

    SHUPK2_Online       : BOOL;
    SHUPK2_RemoteMode   : BOOL;
    SHUPK2_Fault        : BOOL;
    SHUPK2_ActualPower  : REAL;
    SHUPK2_Running      : BOOL;

    SHUPK3_Online       : BOOL;
    SHUPK3_RemoteMode   : BOOL;
    SHUPK3_Fault        : BOOL;
    SHUPK3_ActualPower  : REAL;
    SHUPK3_Running      : BOOL;

    SHUPK4_Online       : BOOL;
    SHUPK4_RemoteMode   : BOOL;
    SHUPK4_Fault        : BOOL;
    SHUPK4_ActualPower  : REAL;
    SHUPK4_Running      : BOOL;

    (* === Выходы на контроллеры котлов ШУПК1-ШУПК4 === *)
    SHUPK1_CmdStart         : BOOL;         // Команда старт
    SHUPK1_CmdStop          : BOOL;         // Команда стоп
    SHUPK1_CmdPressureMode  : BOOL;         // Режим управления (TRUE=давление, FALSE=мощность)
    SHUPK1_CmdPressure      : REAL;         // Уставка давления
    SHUPK1_CmdPower         : REAL;         // Уставка мощности

    SHUPK2_CmdStart         : BOOL;
    SHUPK2_CmdStop          : BOOL;
    SHUPK2_CmdPressureMode  : BOOL;
    SHUPK2_CmdPressure      : REAL;
    SHUPK2_CmdPower         : REAL;

    SHUPK3_CmdStart         : BOOL;
    SHUPK3_CmdStop          : BOOL;
    SHUPK3_CmdPressureMode  : BOOL;
    SHUPK3_CmdPressure      : REAL;
    SHUPK3_CmdPower         : REAL;

    SHUPK4_CmdStart         : BOOL;
    SHUPK4_CmdStop          : BOOL;
    SHUPK4_CmdPressureMode  : BOOL;
    SHUPK4_CmdPressure      : REAL;
    SHUPK4_CmdPower         : REAL;

    (* === Выходы на панель оператора ШУО === *)
    HMI_CascadeActive       : BOOL;         // Каскад активен
    HMI_Stabilizing         : BOOL;         // Идет стабилизация
    HMI_MasterBoilerNum     : INT;          // Номер основного котла (1-4, 0=нет)
    HMI_ActiveBoilersCount  : INT;          // Количество работающих котлов
    HMI_AvailableBoilersCount: INT;         // Количество доступных котлов
    HMI_CommonPressureDisplay: REAL;        // Давление для отображения
    HMI_TotalPower          : REAL;         // Суммарная мощность
    HMI_LastError           : INT;          // Код последней ошибки
    HMI_LastErrorMsg        : STRING(80);   // Сообщение ошибки

    (* Статус каждого котла для HMI *)
    HMI_Boiler1_IsMaster    : BOOL;
    HMI_Boiler1_IsReserve   : BOOL;
    HMI_Boiler1_Available   : BOOL;
    HMI_Boiler1_InCascade   : BOOL;

    HMI_Boiler2_IsMaster    : BOOL;
    HMI_Boiler2_IsReserve   : BOOL;
    HMI_Boiler2_Available   : BOOL;
    HMI_Boiler2_InCascade   : BOOL;

    HMI_Boiler3_IsMaster    : BOOL;
    HMI_Boiler3_IsReserve   : BOOL;
    HMI_Boiler3_Available   : BOOL;
    HMI_Boiler3_InCascade   : BOOL;

    HMI_Boiler4_IsMaster    : BOOL;
    HMI_Boiler4_IsReserve   : BOOL;
    HMI_Boiler4_Available   : BOOL;
    HMI_Boiler4_InCascade   : BOOL;

    (* === Внутренние переменные === *)
    arrBoilersInput     : ARRAY[0..3] OF ST_BoilerData;
    arrBoilersOutput    : ARRAY[0..3] OF ST_BoilerData;
    arrPriorities       : ARRAY[0..3] OF INT;
    stParams            : ST_CascadeParams;
    stStatus            : ST_CascadeStatus;
END_VAR

(* ===== НАЧАЛО ПРОГРАММЫ ===== *)

(* --- Сбор данных от котлов --- *)
(* Котел 1 *)
arrBoilersInput[0].bOnline := SHUPK1_Online;
arrBoilersInput[0].bRemoteMode := SHUPK1_RemoteMode;
arrBoilersInput[0].bFault := SHUPK1_Fault;
arrBoilersInput[0].rActualPower := SHUPK1_ActualPower;
arrBoilersInput[0].bRunning := SHUPK1_Running;

(* Котел 2 *)
arrBoilersInput[1].bOnline := SHUPK2_Online;
arrBoilersInput[1].bRemoteMode := SHUPK2_RemoteMode;
arrBoilersInput[1].bFault := SHUPK2_Fault;
arrBoilersInput[1].rActualPower := SHUPK2_ActualPower;
arrBoilersInput[1].bRunning := SHUPK2_Running;

(* Котел 3 *)
arrBoilersInput[2].bOnline := SHUPK3_Online;
arrBoilersInput[2].bRemoteMode := SHUPK3_RemoteMode;
arrBoilersInput[2].bFault := SHUPK3_Fault;
arrBoilersInput[2].rActualPower := SHUPK3_ActualPower;
arrBoilersInput[2].bRunning := SHUPK3_Running;

(* Котел 4 *)
arrBoilersInput[3].bOnline := SHUPK4_Online;
arrBoilersInput[3].bRemoteMode := SHUPK4_RemoteMode;
arrBoilersInput[3].bFault := SHUPK4_Fault;
arrBoilersInput[3].rActualPower := SHUPK4_ActualPower;
arrBoilersInput[3].bRunning := SHUPK4_Running;


(* --- Сбор приоритетов от оператора --- *)
arrPriorities[0] := HMI_Boiler1Priority;
arrPriorities[1] := HMI_Boiler2Priority;
arrPriorities[2] := HMI_Boiler3Priority;
arrPriorities[3] := HMI_Boiler4Priority;


(* --- Формирование параметров каскада --- *)
stParams.rPressureSetpoint := HMI_PressureSetpoint;
stParams.rPowerConnectThreshold := HMI_PowerConnectThreshold;
stParams.rPowerDisconnectThreshold := HMI_PowerDisconnectThreshold;
stParams.tConnectDelay := HMI_ConnectDelay;
stParams.tDisconnectDelay := HMI_DisconnectDelay;
stParams.tStabilizationTime := HMI_StabilizationTime;
stParams.rReservePowerSetpoint := HMI_ReservePowerSetpoint;
stParams.rPowerRampRate := HMI_PowerRampRate;


(* === Вызов функционального блока каскада === *)
fbCascade(
    bEnable := HMI_CascadeEnable,
    bDisable := HMI_CascadeDisable,
    arrBoilersIn := arrBoilersInput,
    stParams := stParams,
    rCommonPressure := AI_CommonPressure,
    arrPriorities := arrPriorities,
    arrBoilersOut => arrBoilersOutput,
    stStatus => stStatus
);


(* --- Передача команд на контроллеры котлов --- *)
(* Котел 1 *)
SHUPK1_CmdStart := arrBoilersOutput[0].bCmdStart;
SHUPK1_CmdStop := arrBoilersOutput[0].bCmdStop;
SHUPK1_CmdPressureMode := arrBoilersOutput[0].bCmdPressureMode;
SHUPK1_CmdPressure := arrBoilersOutput[0].rCmdPressure;
SHUPK1_CmdPower := arrBoilersOutput[0].rCmdPower;

(* Котел 2 *)
SHUPK2_CmdStart := arrBoilersOutput[1].bCmdStart;
SHUPK2_CmdStop := arrBoilersOutput[1].bCmdStop;
SHUPK2_CmdPressureMode := arrBoilersOutput[1].bCmdPressureMode;
SHUPK2_CmdPressure := arrBoilersOutput[1].rCmdPressure;
SHUPK2_CmdPower := arrBoilersOutput[1].rCmdPower;

(* Котел 3 *)
SHUPK3_CmdStart := arrBoilersOutput[2].bCmdStart;
SHUPK3_CmdStop := arrBoilersOutput[2].bCmdStop;
SHUPK3_CmdPressureMode := arrBoilersOutput[2].bCmdPressureMode;
SHUPK3_CmdPressure := arrBoilersOutput[2].rCmdPressure;
SHUPK3_CmdPower := arrBoilersOutput[2].rCmdPower;

(* Котел 4 *)
SHUPK4_CmdStart := arrBoilersOutput[3].bCmdStart;
SHUPK4_CmdStop := arrBoilersOutput[3].bCmdStop;
SHUPK4_CmdPressureMode := arrBoilersOutput[3].bCmdPressureMode;
SHUPK4_CmdPressure := arrBoilersOutput[3].rCmdPressure;
SHUPK4_CmdPower := arrBoilersOutput[3].rCmdPower;


(* --- Передача статуса на панель оператора --- *)
HMI_CascadeActive := stStatus.bEnabled;
HMI_Stabilizing := stStatus.bStabilizing;
HMI_MasterBoilerNum := stStatus.nMasterBoilerIndex + 1;  // 1-based для оператора
HMI_ActiveBoilersCount := stStatus.nActiveBoilersCount;
HMI_AvailableBoilersCount := stStatus.nAvailableBoilersCount;
HMI_CommonPressureDisplay := stStatus.rCommonPressure;
HMI_TotalPower := stStatus.rTotalPower;
HMI_LastError := stStatus.nLastError;
HMI_LastErrorMsg := stStatus.sLastErrorMsg;

(* Статус котлов для HMI *)
HMI_Boiler1_IsMaster := arrBoilersOutput[0].bIsMaster;
HMI_Boiler1_IsReserve := arrBoilersOutput[0].bIsReserve;
HMI_Boiler1_Available := arrBoilersOutput[0].bAvailable;
HMI_Boiler1_InCascade := arrBoilersOutput[0].bInCascade;

HMI_Boiler2_IsMaster := arrBoilersOutput[1].bIsMaster;
HMI_Boiler2_IsReserve := arrBoilersOutput[1].bIsReserve;
HMI_Boiler2_Available := arrBoilersOutput[1].bAvailable;
HMI_Boiler2_InCascade := arrBoilersOutput[1].bInCascade;

HMI_Boiler3_IsMaster := arrBoilersOutput[2].bIsMaster;
HMI_Boiler3_IsReserve := arrBoilersOutput[2].bIsReserve;
HMI_Boiler3_Available := arrBoilersOutput[2].bAvailable;
HMI_Boiler3_InCascade := arrBoilersOutput[2].bInCascade;

HMI_Boiler4_IsMaster := arrBoilersOutput[3].bIsMaster;
HMI_Boiler4_IsReserve := arrBoilersOutput[3].bIsReserve;
HMI_Boiler4_Available := arrBoilersOutput[3].bAvailable;
HMI_Boiler4_InCascade := arrBoilersOutput[3].bInCascade;

END_PROGRAM
