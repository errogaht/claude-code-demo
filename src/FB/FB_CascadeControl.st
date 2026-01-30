(*
    FB_CascadeControl - Функциональный блок каскадного управления паровыми котлами

    Описание:
    Автоматическое распределение нагрузки между 4 паровыми котлами для поддержания
    стабильного давления в общем паропроводе. Обеспечивает оптимальное покрытие
    потребности в паре и равномерный износ оборудования.

    Автор: Claude Code Demo
    Дата: 2025-01-30
*)
FUNCTION_BLOCK FB_CascadeControl
VAR_INPUT
    (* Команды оператора *)
    bEnable             : BOOL;             // Включить каскадное управление
    bDisable            : BOOL;             // Отключить каскадное управление

    (* Данные от котлов (массив из 4 элементов) *)
    arrBoilersIn        : ARRAY[0..3] OF ST_BoilerData;

    (* Параметры каскада *)
    stParams            : ST_CascadeParams;

    (* Давление в общем паропроводе (от датчика) *)
    rCommonPressure     : REAL;

    (* Приоритеты от оператора *)
    arrPriorities       : ARRAY[0..3] OF INT;   // Приоритеты котлов 0-4
END_VAR

VAR_OUTPUT
    (* Данные на котлы *)
    arrBoilersOut       : ARRAY[0..3] OF ST_BoilerData;

    (* Статус каскада *)
    stStatus            : ST_CascadeStatus;
END_VAR

VAR
    (* Внутренние состояния *)
    bCascadeActive      : BOOL;             // Каскад активен
    nState              : INT := 0;         // Состояние автомата
    i                   : INT;              // Счетчик цикла

    (* Таймеры *)
    tonConnect          : TON;              // Таймер подключения резервного
    tonDisconnect       : TON;              // Таймер отключения резервного
    tonStabilize        : TON;              // Таймер стабилизации

    (* Флаги *)
    bNeedConnect        : BOOL;             // Требуется подключить резервный
    bNeedDisconnect     : BOOL;             // Требуется отключить резервный
    bStabilizationLock  : BOOL;             // Блокировка на время стабилизации

    (* Индексы *)
    nNextReserveToConnect   : INT := -1;    // Индекс следующего резервного для подключения
    nNextReserveToDisconnect: INT := -1;    // Индекс резервного для отключения

    (* Edge detection *)
    bEnableOld          : BOOL;
    bDisableOld         : BOOL;

    (* Ramping для резервных котлов *)
    tCycleTime          : TIME := T#100MS;  // Время цикла ПЛК (настроить под реальное)
    rCycleTimeSec       : REAL;
END_VAR

(* ===== НАЧАЛО ОСНОВНОГО КОДА ===== *)

(* Расчет времени цикла в секундах для ramping *)
rCycleTimeSec := TIME_TO_REAL(tCycleTime) / 1000.0;

(* --- Копирование входных данных и обновление приоритетов --- *)
FOR i := 0 TO 3 DO
    arrBoilersOut[i] := arrBoilersIn[i];

    (* Обновление приоритета от оператора *)
    IF arrPriorities[i] >= 0 AND arrPriorities[i] <= 4 THEN
        arrBoilersOut[i].nPriorityOperator := arrPriorities[i];
        arrBoilersOut[i].nPriority := arrPriorities[i];
    END_IF
END_FOR


(* --- Проверка доступности котлов --- *)
FOR i := 0 TO 3 DO
    arrBoilersOut[i].bAvailable :=
        arrBoilersOut[i].bOnline AND              // На связи
        arrBoilersOut[i].bRemoteMode AND          // Дистанционный режим
        NOT arrBoilersOut[i].bFault AND           // Нет неисправностей
        arrBoilersOut[i].nPriority > 0;           // Приоритет не 0

    (* Если котел недоступен во время работы в каскаде - сбросить приоритет *)
    IF arrBoilersOut[i].bInCascade AND NOT arrBoilersOut[i].bAvailable THEN
        arrBoilersOut[i].nPriority := 0;
        arrBoilersOut[i].bInCascade := FALSE;
        arrBoilersOut[i].bIsMaster := FALSE;
        arrBoilersOut[i].bIsReserve := FALSE;

        (* Установить ошибку *)
        IF NOT arrBoilersOut[i].bOnline THEN
            stStatus.nLastError := 5;
            stStatus.sLastErrorMsg := 'Потеря связи с резервным котлом';
        ELSIF arrBoilersOut[i].bFault THEN
            stStatus.nLastError := 6;
            stStatus.sLastErrorMsg := 'Неисправность резервного котла';
        END_IF
    END_IF
END_FOR


(* --- Подсчет доступных и активных котлов --- *)
stStatus.nAvailableBoilersCount := 0;
stStatus.nActiveBoilersCount := 0;
stStatus.rTotalPower := 0.0;

FOR i := 0 TO 3 DO
    IF arrBoilersOut[i].bAvailable THEN
        stStatus.nAvailableBoilersCount := stStatus.nAvailableBoilersCount + 1;
    END_IF
    IF arrBoilersOut[i].bInCascade AND arrBoilersOut[i].bRunning THEN
        stStatus.nActiveBoilersCount := stStatus.nActiveBoilersCount + 1;
        stStatus.rTotalPower := stStatus.rTotalPower + arrBoilersOut[i].rActualPower;
    END_IF
END_FOR

stStatus.rCommonPressure := rCommonPressure;


(* ===== АВТОМАТ СОСТОЯНИЙ ===== *)
CASE nState OF

    (* --- Состояние 0: Ожидание включения --- *)
    0:
        stStatus.bEnabled := FALSE;
        bCascadeActive := FALSE;

        (* Обнаружение фронта включения *)
        IF bEnable AND NOT bEnableOld THEN
            IF stStatus.nAvailableBoilersCount > 0 THEN
                nState := 10;   // Переход к запуску основного котла
            ELSE
                stStatus.nLastError := 1;
                stStatus.sLastErrorMsg := 'Нет доступных котлов';
            END_IF
        END_IF


    (* --- Состояние 10: Запуск основного котла --- *)
    10:
        stStatus.bEnabled := TRUE;
        bCascadeActive := TRUE;

        (* Найти котел с наивысшим приоритетом *)
        stStatus.nMasterBoilerIndex := FindHighestPriorityBoiler();

        IF stStatus.nMasterBoilerIndex >= 0 THEN
            (* Настроить основной котел *)
            arrBoilersOut[stStatus.nMasterBoilerIndex].bIsMaster := TRUE;
            arrBoilersOut[stStatus.nMasterBoilerIndex].bIsReserve := FALSE;
            arrBoilersOut[stStatus.nMasterBoilerIndex].bInCascade := TRUE;
            arrBoilersOut[stStatus.nMasterBoilerIndex].bCmdPressureMode := TRUE;     // Режим давления
            arrBoilersOut[stStatus.nMasterBoilerIndex].rCmdPressure := stParams.rPressureSetpoint;
            arrBoilersOut[stStatus.nMasterBoilerIndex].bCmdStart := TRUE;

            nState := 20;   // Переход к нормальной работе
        ELSE
            stStatus.nLastError := 1;
            stStatus.sLastErrorMsg := 'Нет доступных котлов';
            nState := 0;
        END_IF


    (* --- Состояние 20: Нормальная работа --- *)
    20:
        (* Сброс команды старта после подтверждения *)
        IF stStatus.nMasterBoilerIndex >= 0 THEN
            IF arrBoilersOut[stStatus.nMasterBoilerIndex].bRunning THEN
                arrBoilersOut[stStatus.nMasterBoilerIndex].bCmdStart := FALSE;
            END_IF
        END_IF

        (* Проверка доступности основного котла *)
        IF stStatus.nMasterBoilerIndex >= 0 THEN
            IF NOT arrBoilersOut[stStatus.nMasterBoilerIndex].bAvailable THEN
                (* Основной котел потерял доступность - попытка переключения *)
                arrBoilersOut[stStatus.nMasterBoilerIndex].bIsMaster := FALSE;
                arrBoilersOut[stStatus.nMasterBoilerIndex].bInCascade := FALSE;

                (* Поиск нового основного *)
                stStatus.nMasterBoilerIndex := FindHighestPriorityBoiler();
                IF stStatus.nMasterBoilerIndex >= 0 THEN
                    (* Переключение резервного на роль основного *)
                    PromoteToMaster(stStatus.nMasterBoilerIndex);
                ELSE
                    (* Нет доступных котлов - аварийное отключение *)
                    stStatus.nLastError := 2;
                    stStatus.sLastErrorMsg := 'Основной котел недоступен';
                    nState := 90;
                END_IF
            END_IF
        END_IF

        (* Логика подключения/отключения резервных котлов *)
        IF NOT bStabilizationLock THEN
            ProcessReserveBoilers();
        END_IF

        (* Ramping мощности для резервных котлов *)
        ProcessPowerRamping();

        (* Обработка команды отключения *)
        IF bDisable AND NOT bDisableOld THEN
            nState := 80;   // Переход к отключению
        END_IF


    (* --- Состояние 80: Отключение каскада --- *)
    80:
        (* Остановить все котлы *)
        FOR i := 0 TO 3 DO
            IF arrBoilersOut[i].bInCascade THEN
                arrBoilersOut[i].bCmdStop := TRUE;
                arrBoilersOut[i].bCmdStart := FALSE;
                arrBoilersOut[i].bInCascade := FALSE;
                arrBoilersOut[i].bIsMaster := FALSE;
                arrBoilersOut[i].bIsReserve := FALSE;
            END_IF
        END_FOR

        stStatus.nMasterBoilerIndex := -1;
        nState := 0;


    (* --- Состояние 90: Аварийная остановка --- *)
    90:
        (* Аварийная остановка всех котлов *)
        FOR i := 0 TO 3 DO
            arrBoilersOut[i].bCmdStop := TRUE;
            arrBoilersOut[i].bCmdStart := FALSE;
            arrBoilersOut[i].bInCascade := FALSE;
            arrBoilersOut[i].bIsMaster := FALSE;
            arrBoilersOut[i].bIsReserve := FALSE;
        END_FOR

        stStatus.nMasterBoilerIndex := -1;
        bCascadeActive := FALSE;
        nState := 0;

END_CASE


(* --- Обновление таймеров --- *)
UpdateTimers();

(* --- Обновление статуса --- *)
stStatus.bStabilizing := bStabilizationLock;
stStatus.bConnecting := tonConnect.Q;
stStatus.bDisconnecting := tonDisconnect.Q;

(* --- Сохранение предыдущих состояний --- *)
bEnableOld := bEnable;
bDisableOld := bDisable;


(* ===== МЕТОДЫ ===== *)
END_FUNCTION_BLOCK


(* ----- Метод: Найти котел с наивысшим приоритетом ----- *)
METHOD PRIVATE FindHighestPriorityBoiler : INT
VAR
    nBestIndex      : INT := -1;
    nBestPriority   : INT := 5;     // Выше максимального
    j               : INT;
END_VAR

FOR j := 0 TO 3 DO
    IF arrBoilersOut[j].bAvailable AND NOT arrBoilersOut[j].bInCascade THEN
        IF arrBoilersOut[j].nPriority > 0 AND arrBoilersOut[j].nPriority < nBestPriority THEN
            nBestPriority := arrBoilersOut[j].nPriority;
            nBestIndex := j;
        END_IF
    END_IF
END_FOR

FindHighestPriorityBoiler := nBestIndex;
END_METHOD


(* ----- Метод: Найти котел с наименьшим приоритетом среди работающих резервных ----- *)
METHOD PRIVATE FindLowestPriorityReserve : INT
VAR
    nWorstIndex     : INT := -1;
    nWorstPriority  : INT := 0;
    j               : INT;
END_VAR

FOR j := 0 TO 3 DO
    IF arrBoilersOut[j].bIsReserve AND arrBoilersOut[j].bInCascade AND arrBoilersOut[j].bRunning THEN
        IF arrBoilersOut[j].nPriority > nWorstPriority THEN
            nWorstPriority := arrBoilersOut[j].nPriority;
            nWorstIndex := j;
        END_IF
    END_IF
END_FOR

FindLowestPriorityReserve := nWorstIndex;
END_METHOD


(* ----- Метод: Найти следующий резервный котел для подключения ----- *)
METHOD PRIVATE FindNextReserveToConnect : INT
VAR
    nBestIndex      : INT := -1;
    nBestPriority   : INT := 5;
    j               : INT;
END_VAR

FOR j := 0 TO 3 DO
    IF arrBoilersOut[j].bAvailable AND
       NOT arrBoilersOut[j].bInCascade AND
       NOT arrBoilersOut[j].bIsMaster AND
       arrBoilersOut[j].nPriority > 0 THEN
        IF arrBoilersOut[j].nPriority < nBestPriority THEN
            nBestPriority := arrBoilersOut[j].nPriority;
            nBestIndex := j;
        END_IF
    END_IF
END_FOR

FindNextReserveToConnect := nBestIndex;
END_METHOD


(* ----- Метод: Повысить резервный до основного ----- *)
METHOD PRIVATE PromoteToMaster
VAR_INPUT
    nBoilerIndex : INT;
END_VAR

IF nBoilerIndex >= 0 AND nBoilerIndex <= 3 THEN
    arrBoilersOut[nBoilerIndex].bIsMaster := TRUE;
    arrBoilersOut[nBoilerIndex].bIsReserve := FALSE;
    arrBoilersOut[nBoilerIndex].bCmdPressureMode := TRUE;
    arrBoilersOut[nBoilerIndex].rCmdPressure := stParams.rPressureSetpoint;
END_IF
END_METHOD


(* ----- Метод: Обработка резервных котлов ----- *)
METHOD PRIVATE ProcessReserveBoilers
VAR
    rMasterPower    : REAL;
    nReserveIdx     : INT;
END_VAR

(* Получить мощность основного котла *)
IF stStatus.nMasterBoilerIndex >= 0 THEN
    rMasterPower := arrBoilersOut[stStatus.nMasterBoilerIndex].rActualPower;
ELSE
    RETURN;
END_IF

(* --- Логика подключения резервного котла --- *)
(* Условие: мощность основного выше порога *)
bNeedConnect := (rMasterPower >= stParams.rPowerConnectThreshold);

(* Таймер подключения *)
tonConnect(IN := bNeedConnect AND NOT bStabilizationLock,
           PT := stParams.tConnectDelay);

IF tonConnect.Q THEN
    (* Найти следующий резервный для подключения *)
    nReserveIdx := FindNextReserveToConnect();

    IF nReserveIdx >= 0 THEN
        (* Подключить резервный котел *)
        arrBoilersOut[nReserveIdx].bIsReserve := TRUE;
        arrBoilersOut[nReserveIdx].bIsMaster := FALSE;
        arrBoilersOut[nReserveIdx].bInCascade := TRUE;
        arrBoilersOut[nReserveIdx].bCmdPressureMode := FALSE;    // Режим мощности
        arrBoilersOut[nReserveIdx].rPowerSetpoint := stParams.rMinPower;  // Начать с минимума
        arrBoilersOut[nReserveIdx].rCmdPower := stParams.rMinPower;
        arrBoilersOut[nReserveIdx].bCmdStart := TRUE;

        (* Запустить таймер стабилизации *)
        StartStabilization();
    END_IF
END_IF


(* --- Логика отключения резервного котла --- *)
(* Условие: мощность основного ниже порога И есть работающие резервные *)
bNeedDisconnect := (rMasterPower <= stParams.rPowerDisconnectThreshold) AND
                   (stStatus.nActiveBoilersCount > 1);

(* Таймер отключения *)
tonDisconnect(IN := bNeedDisconnect AND NOT bStabilizationLock,
              PT := stParams.tDisconnectDelay);

IF tonDisconnect.Q THEN
    (* Найти резервный с наименьшим приоритетом *)
    nReserveIdx := FindLowestPriorityReserve();

    IF nReserveIdx >= 0 THEN
        (* Отключить резервный котел *)
        arrBoilersOut[nReserveIdx].bCmdStop := TRUE;
        arrBoilersOut[nReserveIdx].bCmdStart := FALSE;
        arrBoilersOut[nReserveIdx].bInCascade := FALSE;
        arrBoilersOut[nReserveIdx].bIsReserve := FALSE;

        (* Запустить таймер стабилизации *)
        StartStabilization();
    END_IF
END_IF

END_METHOD


(* ----- Метод: Ramping мощности для резервных котлов ----- *)
METHOD PRIVATE ProcessPowerRamping
VAR
    j               : INT;
    rDelta          : REAL;
    rTargetPower    : REAL;
END_VAR

rDelta := stParams.rPowerRampRate * rCycleTimeSec;
rTargetPower := stParams.rReservePowerSetpoint;

FOR j := 0 TO 3 DO
    IF arrBoilersOut[j].bIsReserve AND arrBoilersOut[j].bInCascade THEN
        (* Постепенное увеличение мощности до уставки *)
        IF arrBoilersOut[j].rPowerSetpoint < rTargetPower THEN
            arrBoilersOut[j].rPowerSetpoint := arrBoilersOut[j].rPowerSetpoint + rDelta;
            IF arrBoilersOut[j].rPowerSetpoint > rTargetPower THEN
                arrBoilersOut[j].rPowerSetpoint := rTargetPower;
            END_IF
        END_IF

        (* Ограничение мощности *)
        IF arrBoilersOut[j].rPowerSetpoint < stParams.rMinPower THEN
            arrBoilersOut[j].rPowerSetpoint := stParams.rMinPower;
        ELSIF arrBoilersOut[j].rPowerSetpoint > stParams.rMaxPower THEN
            arrBoilersOut[j].rPowerSetpoint := stParams.rMaxPower;
        END_IF

        (* Применить уставку *)
        arrBoilersOut[j].rCmdPower := arrBoilersOut[j].rPowerSetpoint;
    END_IF
END_FOR

END_METHOD


(* ----- Метод: Запуск стабилизации ----- *)
METHOD PRIVATE StartStabilization
    bStabilizationLock := TRUE;
    tonStabilize(IN := FALSE, PT := T#0S);  // Сброс таймера
END_METHOD


(* ----- Метод: Обновление таймеров ----- *)
METHOD PRIVATE UpdateTimers

(* Таймер стабилизации *)
tonStabilize(IN := bStabilizationLock, PT := stParams.tStabilizationTime);

IF tonStabilize.Q THEN
    bStabilizationLock := FALSE;
END_IF

(* Обновление оставшегося времени в статусе *)
IF tonConnect.IN THEN
    stStatus.tConnectRemaining := stParams.tConnectDelay - tonConnect.ET;
ELSE
    stStatus.tConnectRemaining := T#0S;
END_IF

IF tonDisconnect.IN THEN
    stStatus.tDisconnectRemaining := stParams.tDisconnectDelay - tonDisconnect.ET;
ELSE
    stStatus.tDisconnectRemaining := T#0S;
END_IF

IF tonStabilize.IN THEN
    stStatus.tStabilizeRemaining := stParams.tStabilizationTime - tonStabilize.ET;
ELSE
    stStatus.tStabilizeRemaining := T#0S;
END_IF

END_METHOD
