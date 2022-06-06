classdef LiveDataAppBasic < matlab.apps.AppBase

    % Properties that correspond to app components
    properties (Access = public)
        LiveDataAcquisitionUIFigure    matlab.ui.Figure
        LiveViewPanel                  matlab.ui.container.Panel
        TimewindowEditField            matlab.ui.control.NumericEditField
        TimewindowsEditFieldLabel      matlab.ui.control.Label
        YmaxEditField                  matlab.ui.control.NumericEditField
        YmaxEditFieldLabel             matlab.ui.control.Label
        YminEditField                  matlab.ui.control.NumericEditField
        YminEditFieldLabel             matlab.ui.control.Label
        AutoscaleYSwitch               matlab.ui.control.Switch
        AutoscaleYSwitchLabel          matlab.ui.control.Label
        LiveAxes                       matlab.ui.control.UIAxes
        LiveDataAcquisitionLabel       matlab.ui.control.Label
        DevicePanel                    matlab.ui.container.Panel
        ExcitationSourceDropDown       matlab.ui.control.DropDown
        ExcitationSourceDropDownLabel  matlab.ui.control.Label
        RateSlider                     matlab.ui.control.Slider
        RatescanssSliderLabel          matlab.ui.control.Label
        RateEdit                       matlab.ui.control.NumericEditField
        DeviceDropDown                 matlab.ui.control.DropDown
        DeviceDropDownLabel            matlab.ui.control.Label
        CouplingDropDown               matlab.ui.control.DropDown
        CouplingDropDownLabel          matlab.ui.control.Label
        TerminalConfigDropDown         matlab.ui.control.DropDown
        TerminalConfigDropDownLabel    matlab.ui.control.Label
        RangeDropDown                  matlab.ui.control.DropDown
        RangeDropDownLabel             matlab.ui.control.Label
        MeasurementTypeDropDown        matlab.ui.control.DropDown
        MeasurementTypeDropDownLabel   matlab.ui.control.Label
        Channel1DropDown               matlab.ui.control.DropDown
        Channel1DropDownLabel          matlab.ui.control.Label
        Channel2DropDown               matlab.ui.control.DropDown
        Channel2DropDownLabel          matlab.ui.control.Label
        AcquisitionPanel               matlab.ui.container.Panel
        LogStatusText                  matlab.ui.control.Label
        LogdatatofileSwitch            matlab.ui.control.Switch
        LogdatatofileSwitchLabel       matlab.ui.control.Label
        StopButton                     matlab.ui.control.Button
        StartButton                    matlab.ui.control.Button
    end

    % 2018/02/09 version 1.0 Andrei Ursache
    % 2019/01/07 version 1.2, AU, Added IEPE measurement type
    % 2020/01/16 version 1.3, AU, updated DAQ code from Session to DataAcquisition interface
    
    % Copyright 2018-2020 The MathWorks, Inc.

    
    properties (Access = private)
        DAQ                   % Handle to DAQ object
        DAQMeasurementTypes = {'Voltage','IEPE','Audio'};  % DAQ input measurement types supported by the app
        DAQSubsystemTypes = {'AnalogInput','AudioInput'};  % DAQ subsystem types supported by the app
        DevicesInfo           % Array of devices that provide analog input voltage or audio input measurements
        LogRequested          % Logical value, indicates whether user selected to log data to file from the UI (set by LogdatatofileSwitch)
        TimestampsFIFOBuffer  % Timestamps FIFO buffer used for live plot of latest "N" seconds of acquired data
        DataFIFOBuffer        % Data FIFO buffer used for live plot of latest "N" seconds of acquired data
        DataFIFOBuffer2        % Data FIFO buffer used for live plot of latest "N" seconds of acquired data
        FIFOMaxSize = 1E+6    % Maximum allowed FIFO buffer size for DataFIFOBuffer and TimestampsFIFOBuffer
        LivePlotLine          % Handle to line plot of acquired data
        LivePlotLine2          % Handle to line plot of acquired data

        TriggerTime           % Acquisition start time stored as datetime
        TempFilename          % Temporary binary file name, acquired data is logged to this file during acquisition
        TempFile              % Handle of opened binary file, acquired data is logged to this file during acquisition
        Filename = 'daqdata.mat' % Default MAT file name at app start
        Filepath = pwd        % Default folder for saving the MAT file at app start
    end
    
    methods (Access = private)
        
        
        function scansAvailable_Callback(app, src, ~)
        %scansAvailable_Callback Executes on DAQ object ScansAvailable event
        %  This callback function gets executed periodically as more data is acquired.
        %  For a smooth live plot update, it stores the latest N seconds
        %  (specified time window) of acquired data and relative timestamps in FIFO
        %  buffers. A live plot is updated with the data in the FIFO buffer.
        %  If data logging option is selected in the UI, it also writes data to a
        %  binary file.
            
            if ~isvalid(app)
                return
            end
            
            [data,timestamps,triggertime] = read(src, src.ScansAvailableFcnCount, 'OutputFormat','Matrix');
            
            if app.LogRequested
                % If Log data to file switch is on
                latestdata = [timestamps, data]';
                fwrite(app.TempFile, latestdata, 'double');
                if timestamps(1)==0
                    app.TriggerTime = triggertime;
                end
            end
            
            % Store continuous acquisition data in FIFO data buffers
            buffersize = round(app.DAQ.Rate * app.TimewindowEditField.Value) + 1;
            app.TimestampsFIFOBuffer = storeDataInFIFO(app, app.TimestampsFIFOBuffer, buffersize, timestamps);
            app.DataFIFOBuffer = storeDataInFIFO(app, app.DataFIFOBuffer, buffersize, data(:,1));
            app.DataFIFOBuffer2 = storeDataInFIFO(app, app.DataFIFOBuffer2, buffersize, data(:,2));

            
            % Update plot data
            set(app.LivePlotLine, 'XData', app.TimestampsFIFOBuffer, 'YData', app.DataFIFOBuffer);
            set(app.LivePlotLine2, 'XData', app.TimestampsFIFOBuffer, 'YData', app.DataFIFOBuffer2);

            if numel(app.TimestampsFIFOBuffer) > 1
                xlim(app.LiveAxes, [app.TimestampsFIFOBuffer(1), app.TimestampsFIFOBuffer(end)])
            end
        end
        
        function data = storeDataInFIFO(~, data, buffersize, datablock)
        %storeDataInFIFO Store continuous acquisition data in a FIFO data buffer
        %  Storing data in a finite-size FIFO buffer is used to plot the latest "N" seconds of acquired data for
        %  a smooth live plot update and without continuously increasing memory use.
        %  The most recently acquired data (datablock) is added to the buffer and if the amount of data in the
        %  buffer exceeds the specified buffer size (buffersize) the oldest data is discarded to cap the size of
        %  the data in the buffer to buffersize.
        %  input data is the existing data buffer (column vector Nx1).
        %  buffersize is the desired buffer size (maximum number of rows in data buffer) and can be changed.
        %  datablock is a new data block to be added to the buffer (column vector Kx1).
        %  output data is the updated data buffer (column vector Mx1).
        
            % If the data size is greater than the buffer size, keep only the
            % the latest "buffer size" worth of data
            % This can occur if the buffer size is changed to a lower value during acquisition
            if size(data,1) > buffersize
                data = data(end-buffersize+1:end,:);
            end
            
            if size(datablock,1) < buffersize
                % Data block size (number of rows) is smaller than the buffer size
                if size(data,1) == buffersize
                    % Current data size is already equal to buffer size.
                    % Discard older data and append new data block,
                    % and keep data size equal to buffer size.
                    shiftPosition = size(datablock,1);
                    data = circshift(data,-shiftPosition);
                    data(end-shiftPosition+1:end,:) = datablock;
                elseif (size(data,1) < buffersize) && (size(data,1)+size(datablock,1) > buffersize)
                    % Current data size is less than buffer size and appending the new
                    % data block results in a size greater than the buffer size.
                    data = [data; datablock];
                    shiftPosition = size(data,1) - buffersize;
                    data = circshift(data,-shiftPosition);
                    data(buffersize+1:end, :) = [];
                else
                    % Current data size is less than buffer size and appending the new
                    % data block results in a size smaller than or equal to the buffer size.
                    % (if (size(data,1) < buffersize) && (size(data,1)+size(datablock,1) <= buffersize))
                    data = [data; datablock];
                end
            else
                % Data block size (number of rows) is larger than or equal to buffer size
                data = datablock(end-buffersize+1:end,:);
            end
        end
        
        function [items, itemsData] = getChannelPropertyOptions(~, subsystem, propertyName)
        %getChannelPropertyOptions Get options available for a DAQ channel property
        %  Returns items and itemsData for displaying options in a dropdown component
        %  subsystem is the DAQ subsystem handle corresponding to the DAQ channel
        %  propertyName is channel property name as a character array, and can be
        %    'TerminalConfig', or 'Coupling', or 'Range'.
        %  items is a cell array of possible property values, for example {'DC', 'AC'}
        %  itemsData is [] (empty) for 'TerminalConfig' and 'Coupling', and is a cell array of
        %     available ranges for 'Range', for example {[-10 10], [-1 1]}
            
            switch propertyName
                case 'TerminalConfig'
                    items = cellstr(string(subsystem.TerminalConfigsAvailable));
                    itemsData = [];
                case 'Coupling'
                    items = cellstr(string(subsystem.CouplingsAvailable));
                    itemsData = [];
                case 'Range'
                    numRanges = numel(subsystem.RangesAvailable);
                    items = strings(numRanges,1);
                    itemsData = cell(numRanges,1);
                    for ii = 1:numRanges
                        range = subsystem.RangesAvailable(ii);
                        items(ii) = sprintf('%.2f to %.2f', range.Min, range.Max);
                        itemsData{ii} = [range.Min range.Max];
                    end
                    items = cellstr(items);                    
                case 'ExcitationSource'
                    items = {'Internal','External','None'};
                    itemsData = [];
            end
        end
        
        
        function setAppViewState(app, state)
        %setAppViewState Sets the app in a new state and enables/disables corresponding components
        %  state can be 'deviceselection', 'configuration', 'acquisition', or 'filesave'
        
            switch state                
                case 'deviceselection'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.DeviceDropDown.Enable = 'on';
                    app.Channel1DropDown.Enable = 'off';
                    app.Channel2DropDown.Enable = 'off';
                    app.MeasurementTypeDropDown.Enable = 'off';
                    app.RangeDropDown.Enable = 'off';
                    app.TerminalConfigDropDown.Enable = 'off';
                    app.CouplingDropDown.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.ExcitationSourceDropDown.Enable = 'off';
                    app.StopButton.Enable = 'off';
                    app.TimewindowEditField.Enable = 'off';
                case 'configuration'
                    app.RateEdit.Enable = 'on';
                    app.RateSlider.Enable = 'on';
                    app.DeviceDropDown.Enable = 'on';
                    app.Channel1DropDown.Enable = 'on';
                    app.Channel2DropDown.Enable = 'on';
                    app.MeasurementTypeDropDown.Enable = 'on';
                    app.RangeDropDown.Enable = 'on';
                    app.StartButton.Enable = 'on';
                    app.LogdatatofileSwitch.Enable = 'on';
                    app.StopButton.Enable = 'off';
                    app.TimewindowEditField.Enable = 'on';

                    switch app.DAQ.Channels(1).MeasurementType
                        case 'Voltage'
                            % Voltage channels do not have ExcitationSource
                            % property, so disable the corresponding UI controls
                            app.TerminalConfigDropDown.Enable = 'on';
                            app.CouplingDropDown.Enable = 'on';
                            app.ExcitationSourceDropDown.Enable = 'off';
                        case 'Audio'
                            % Audio channels do not have TerminalConfig, Coupling, and ExcitationSource
                            % properties, so disable the corresponding UI controls
                            app.TerminalConfigDropDown.Enable = 'off';
                            app.CouplingDropDown.Enable = 'off';
                            app.ExcitationSourceDropDown.Enable = 'off';
                        case 'IEPE'
                            app.TerminalConfigDropDown.Enable = 'on';
                            app.CouplingDropDown.Enable = 'on';
                            app.ExcitationSourceDropDown.Enable = 'on';
                    end
                case 'acquisition'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.DeviceDropDown.Enable = 'off';
                    app.Channel1DropDown.Enable = 'off';
                    app.Channel2DropDown.Enable = 'off';
                    app.MeasurementTypeDropDown.Enable = 'off';
                    app.RangeDropDown.Enable = 'off';
                    app.TerminalConfigDropDown.Enable = 'off';
                    app.CouplingDropDown.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.ExcitationSourceDropDown.Enable = 'off';
                    app.StopButton.Enable = 'on';
                    app.TimewindowEditField.Enable = 'on';
                    updateLogdatatofileSwitchComponents(app)
                case 'filesave'
                    app.RateEdit.Enable = 'off';
                    app.RateSlider.Enable = 'off';
                    app.DeviceDropDown.Enable = 'off';
                    app.Channel1DropDown.Enable = 'off';
                    app.Channel2DropDown.Enable = 'off';
                    app.MeasurementTypeDropDown.Enable = 'off';
                    app.RangeDropDown.Enable = 'off';
                    app.TerminalConfigDropDown.Enable = 'off';
                    app.CouplingDropDown.Enable = 'off';
                    app.StartButton.Enable = 'off';
                    app.LogdatatofileSwitch.Enable = 'off';
                    app.ExcitationSourceDropDown.Enable = 'off';
                    app.StopButton.Enable = 'off';
                    app.TimewindowEditField.Enable = 'on';
                    updateLogdatatofileSwitchComponents(app)   
            end
        end
        
        
        function binFile2MAT(~, filenameIn, filenameOut, numColumns, metadata)
        %BINFILE2MAT Loads 2-D array of doubles from binary file and saves data to MAT file
        % Processes all data in binary file (filenameIn) and saves it to a MAT file without loading
        % all data to memory.
        % If output MAT file (filenameOut) already exists, data is overwritten (not appended).
        % Input binary file is a matrix of doubles with numRows x numColumns
        % MAT file (filenameOut) is a MAT file with the following variables
        %   timestamps = a column vector ,  the first column in the data from binary file
        %   data = a 2-D array of doubles, includes 2nd-last columns in the data from binary file
        %   metatada = a structure, which is provided as input argument, used to provide additional
        %              data information
        %
            
            % If filenameIn does not exist, error out
            if ~exist(filenameIn, 'file')
                error('Input binary file ''%s'' not found. Specify a different file name.', filenameIn);
            end
            
            % If output MAT file already exists, delete it
            if exist(filenameOut, 'file')
                delete(filenameOut)
            end
            
            % Determine number of rows in the binary file
            % Expecting the number of bytes in the file to be 8*numRows*numColumns
            fileInfo = dir(filenameIn);
            numRows = floor(fileInfo.bytes/(8*double(numColumns)));
            
            % Create matfile object to save data loaded from binary file
            matObj = matfile(filenameOut);
            matObj.Properties.Writable = true;
            
            % Initialize MAT file
            matObj.timestamps(numRows,1) = 0;
            matObj.data(numRows,1:numColumns-1) = 0;
            
            % Open input binary file
            fid = fopen(filenameIn,'r');
            
            % Specify how many rows to process(load and save) at a time
            numRowsPerChunk = 10E+6;
            
            % Keeps track of how many rows have been processed so far
            ii = 0;
            
            while(ii < numRows)
                
                % chunkSize = how many rows to process in this iteration
                % If it's the last iteration, it's possible the number of rows left to
                % process is different from the specified numRowsPerChunk
                chunkSize = min(numRowsPerChunk, numRows-ii);
                
                data = fread(fid, [numColumns,chunkSize], 'double');
                
                matObj.timestamps((ii+1):(ii+chunkSize), 1) = data(1,:)';
                matObj.data((ii+1):(ii+chunkSize), 1:2) = data(2:3,:)';

                ii = ii + chunkSize;
            end
            
            fclose(fid);
            
            % Save provided metadata to MAT file
            matObj.metadata = metadata;
        end
        
        function deviceinfo = daqListSupportedDevices(app, subsystemTypes, measurementTypes)
        %daqListSupportedDevices Get connected devices that support the specified subsystem and measurement types      
            
            % Detect all connected devices
            devices = daqlist;
            deviceinfo = devices.DeviceInfo;
            
            % Keep a subset of devices which have the specified subystem and measurement types
            deviceinfo = daqFilterDevicesBySubsystem(app, deviceinfo, subsystemTypes);
            deviceinfo = daqFilterDevicesByMeasurement(app, deviceinfo, measurementTypes);
            
        end
                
        function filteredDevices = daqFilterDevicesBySubsystem(~, devices, subsystemTypes)
        %daqFilterDevicesBySubsystem Filter DAQ device array by subsystem type
        %  devices is a DAQ device info array
        %  subsystemTypes is a cell array of DAQ subsystem types, for example {'AnalogInput, 'AnalogOutput'}
        %  filteredDevices is the filtered DAQ device info array
            
            % Logical array indicating if device has any of the subsystem types provided
            hasSubsystemArray = false(numel(devices), 1);
            
            % Go through each device and see if it has any of the subsystem types provided
            for ii = 1:numel(devices)
                hasSubsystem = false;
                for jj = 1:numel(subsystemTypes)
                    hasSubsystem = hasSubsystem || ...
                        any(strcmp({devices(ii).Subsystems.SubsystemType}, subsystemTypes{jj}));
                end
                hasSubsystemArray(ii) = hasSubsystem;
            end
            filteredDevices = devices(hasSubsystemArray);
        end
        
        function filteredDevices = daqFilterDevicesByMeasurement(~, devices, measurementTypes)
        %daqFilterDevicesByMeasurement Filter DAQ device array by measurement type
        %  devices is a DAQ device info array
        %  measurementTypes is a cell array of measurement types, for example {'Voltage, 'Current'}
        %  filteredDevices is the filtered DAQ device info array
            
            % Logical array indicating if device has any of the measurement types provided
            hasMeasurementArray = false(numel(devices), 1);
            
            % Go through each device and subsystem and see if it has any of the measurement types provided
            for ii = 1:numel(devices)
                % Get array of available subsystems for the current device
                subsystems = [devices(ii).Subsystems];
                hasMeasurement = false;
                for jj = 1:numel(subsystems)
                    % Get cell array of available measurement types for the current subsystem
                    measurements = subsystems(jj).MeasurementTypesAvailable;
                    for kk = 1:numel(measurementTypes)
                        hasMeasurement = hasMeasurement || ...
                            any(strcmp(measurements, measurementTypes{kk}));
                    end
                end
                hasMeasurementArray(ii) = hasMeasurement;
            end
            filteredDevices = devices(hasMeasurementArray);
        end
        
        function updateRateUIComponents(app)
        %updateRateUIComponents Updates UI with current rate and time window limits
            
            % Update UI to show the actual data acquisition rate and limits
            value = app.DAQ.Rate;
            app.RateEdit.Limits = app.DAQ.RateLimit;
            app.RateSlider.Limits = app.DAQ.RateLimit;
            app.RateSlider.MajorTicks = [app.DAQ.RateLimit(1) app.DAQ.RateLimit(2)];
            app.RateSlider.MinorTicks = [];
            app.RateEdit.Value = value;
            app.RateSlider.Value = value;
            
            % Update time window limits
            % Minimum time window shows 2 samples
            % Maximum time window corresponds to the maximum specified FIFO buffer size
            minTimeWindow = 1/value;
            maxTimeWindow = app.FIFOMaxSize / value;
            app.TimewindowEditField.Limits = [minTimeWindow, maxTimeWindow];
            
        end
        
        
        function closeApp_Callback(app, ~, event, isAcquiring)
        %closeApp_Callback Clean-up after "Close Confirm" dialog window
        %  "Close Confirm" dialog window is called from CloseRequestFcn
        %  of the app UIFigure.
        %   event is the event data of the UIFigure CloseRequestFcn callback.
        %   isAcquiring is a logical flag (true/false) corresponding to DAQ
        %   running state.            
            
            %   Before closing app if acquisition is currently on (isAcquiring=true) clean-up 
            %   data acquisition object and close file if logging.
            switch event.SelectedOption
                case 'OK'
                    if isAcquiring
                        % Acquisition is currently on
                        stop(app.DAQ)
                        delete(app.DAQ)
                        if app.LogRequested
                            fclose(app.TempFile);
                        end
                    else
                        % Acquisition is stopped
                    end

                    delete(app)
                case 'Cancel'
                    % Continue
            end
            
        end
        
        function updateAutoscaleYSwitchComponents(app)
        %updateAutoscaleYSwitchComponents Updates UI components related to y-axis autoscale
        
            value = app.AutoscaleYSwitch.Value;
            switch value
                case 'Off'
                    app.YminEditField.Enable = 'on';
                    app.YmaxEditField.Enable = 'on';
                    YmaxminValueChanged(app, []);
                case 'On'
                    app.YminEditField.Enable = 'off';
                    app.YmaxEditField.Enable = 'off';
                    app.LiveAxes.YLimMode = 'auto';
            end
        end
        
        function updateChannelMeasurementComponents(app)
        %updateChannelMeasurementComponents Updates channel properties and measurement UI components
            measurementType = app.MeasurementTypeDropDown.Value;

            % Get selected DAQ device index (to be used with DaqDevicesInfo list)
            deviceIndex = app.DeviceDropDown.Value - 1;
            deviceID = app.DevicesInfo(deviceIndex).ID;
            vendor = app.DevicesInfo(deviceIndex).Vendor.ID;
                        
            % Get DAQ subsystem information (analog input or audio input)
            % Analog input or analog output subsystems are the first subsystem of the device
            subsystem = app.DevicesInfo(deviceIndex).Subsystems(1);
            
            % Delete existing data acquisition object
            delete(app.DAQ);
            app.DAQ = [];
            
            % Create a new data acquisition object
            d = daq(vendor);
            addinput(d, deviceID, app.Channel1DropDown.Value, measurementType);
            addinput(d, deviceID, app.Channel2DropDown.Value, measurementType);
         
            % Configure DAQ ScansAvailableFcn callback function
            d.ScansAvailableFcn = @(src,event) scansAvailable_Callback(app, src, event);
            
            % Store data acquisition object handle in DAQ app property
            app.DAQ = d;
             
            % Only 'Voltage', 'IEPE' and 'Audio' measurement types are supported in this version of the app
            % Depending on what type of device is selected, populate the UI elements channel properties
            switch subsystem.SubsystemType
                case 'AnalogInput'                                       
                    % Populate dropdown with available channel 'TerminalConfig' options
                    app.TerminalConfigDropDown.Items = getChannelPropertyOptions(app, subsystem, 'TerminalConfig');
                    % Update UI with the actual channel property value
                    % (default value is not necessarily first in the list)
                    % DropDown Value must be set as a character array in MATLAB R2017b
                    app.TerminalConfigDropDown.Value = d.Channels(1).TerminalConfig;
                    app.TerminalConfigDropDown.Tag = 'TerminalConfig';
                    
                    % Populate dropdown with available channel 'Coupling' options
                    app.CouplingDropDown.Items =  getChannelPropertyOptions(app, subsystem, 'Coupling');
                    % Update UI with the actual channel property value
                    app.CouplingDropDown.Value = d.Channels(1).Coupling;
                    app.CouplingDropDown.Tag = 'Coupling';
                                        
                    % Populate dropdown with available channel 'ExcitationSource' options
                    if strcmpi(measurementType, 'IEPE')
                        app.ExcitationSourceDropDown.Items = getChannelPropertyOptions(app, subsystem, 'ExcitationSource');
                        app.ExcitationSourceDropDown.Value = d.Channels(1).ExcitationSource;
                        app.ExcitationSourceDropDown.Tag = 'ExcitationSource';
                    else
                        app.ExcitationSourceDropDown.Items = {''};
                    end
                    
                    ylabel(app.LiveAxes, 'Voltage (V)')
                                        
                case 'AudioInput'
                    ylabel(app.LiveAxes, 'Normalized amplitude')
            end
            
            % Update UI with current rate and time window limits
            updateRateUIComponents(app)
                    
            % Populate dropdown with available 'Range' options
            [rangeItems, rangeItemsData] = getChannelPropertyOptions(app, subsystem, 'Range');
            app.RangeDropDown.Items = rangeItems;
            app.RangeDropDown.ItemsData = rangeItemsData;
            
            % Update UI with current channel 'Range'
            currentRange = d.Channels(1).Range;
            app.RangeDropDown.Value = [currentRange.Min currentRange.Max];
            app.RangeDropDown.Tag = 'Range';
            
            app.DeviceDropDown.Items{1} = 'Deselect device';
            
            % Enable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'configuration');
        end
        
        function updateLogdatatofileSwitchComponents(app)
            value = app.LogdatatofileSwitch.Value;
            switch value
                case 'Off'
                    app.LogRequested = false;
                case 'On'
                    app.LogRequested = true;
            end
        end
    end
    

    % Callbacks that handle component events
    methods (Access = private)

        % Code that executes after component creation
        function startupFcn(app)
            
            % This function executes when the app starts, before user interacts with UI
            
            % Set the app controls in device selection state
            setAppViewState(app, 'deviceselection');
            drawnow
            
            % Get connected devices that have the supported subsystem and measurement types
            devices = daqListSupportedDevices(app, app.DAQSubsystemTypes, app.DAQMeasurementTypes);
            
            % Store DAQ device information (filtered list) into DevicesInfo app property
            % This is used by other functions in the app
            app.DevicesInfo = devices;
           
            % Populate the device drop down list with cell array of composite device names (ID + model)
            % First element is "Select a device"
            deviceDescriptions = cellstr(string({devices.ID}') + " [" + string({devices.Model}') + "]");
            app.DeviceDropDown.Items = ['Select a device'; deviceDescriptions];
            
            % Assign dropdown ItemsData to correspond to device index + 1
            % (first item is not a device)
            app.DeviceDropDown.ItemsData = 1:numel(devices)+1;
            
            % Create a line plot and store its handle in LivePlot app property
            % This is used for updating the live plot from scansAvailable_Callback function
            app.LivePlotLine = plot(app.LiveAxes, NaN, NaN);
            hold(app.LiveAxes, "on");
            app.LivePlotLine2 = plot(app.LiveAxes, NaN, NaN);
            
            % Turn off axes toolbar and data tips for live plot axes
            app.LiveAxes.Toolbar.Visible = 'off';
            disableDefaultInteractivity(app.LiveAxes);
            
            % Initialize the AutoscaleYSwitch, YminSpinner, and YmaxSpinner components in the correct
            % state (AutoscaleYSwitch enabled, YminSpinner and YmaxSpinner disabled).
            updateAutoscaleYSwitchComponents(app)

        end

        % Value changed function: DeviceDropDown
        function DeviceDropDownValueChanged(app, ~)
            value = app.DeviceDropDown.Value;
            
            if ~isempty(value)
                % Device index is offset by 1 because first element in device dropdown
                % is "Select a device" (not a device).
                deviceIndex = value-1 ;
                
                % Reset channel property options
                app.Channel1DropDown.Items = {''};
                app.Channel2DropDown.Items = {''};
                app.MeasurementTypeDropDown.Items = {''};
                app.RangeDropDown.Items = {''};
                app.TerminalConfigDropDown.Items = {''};
                app.CouplingDropDown.Items = {''};
                app.ExcitationSourceDropDown.Items = {''};
                setAppViewState(app, 'deviceselection');

                
                % Delete data acquisition object, as a new one will be created for the newly selected device
                delete(app.DAQ);
                app.DAQ = [];
                
                if deviceIndex > 0
                    % If a device is selected
                    
                    % Get subsystem information to update channel dropdown list and channel property options
                    % For devices that have an analog input or an audio input subsystem, this is the first subsystem
                    subsystem = app.DevicesInfo(deviceIndex).Subsystems(1);
                    app.Channel1DropDown.Items = cellstr(string(subsystem.ChannelNames));
                    app.Channel2DropDown.Items = cellstr(string(subsystem.ChannelNames));
                    app.Channel2DropDown.Value = app.Channel2DropDown.Items(2);
                                        
                    % Populate available measurement types for the selected device
                    app.MeasurementTypeDropDown.Items = intersect(app.DAQMeasurementTypes,...
                                subsystem.MeasurementTypesAvailable, 'stable');

                    % Update channel and channel property options
                    updateChannelMeasurementComponents(app)

                else
                    % If no device is selected

                    % Delete existing data acquisition object
                    delete(app.DAQ);
                    app.DAQ = [];
                    
                    app.DeviceDropDown.Items{1} = 'Select a device';

                    setAppViewState(app, 'deviceselection');
                end
            end
        end

        % Button pushed function: StartButton
        function StartButtonPushed(app, ~)
                               
            % Disable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'acquisition');               
            
            if app.LogRequested
                % If Log data to file switch is on
                % Create and open temporary binary file to log data to disk
                app.TempFilename = tempname;
                app.TempFile = fopen(app.TempFilename, 'w');
            end
            
            % Reset FIFO buffer data
            app.DataFIFOBuffer = [];
            app.TimestampsFIFOBuffer = [];

            app.DataFIFOBuffer2 = [];
            
            try
                start(app.DAQ,'continuous');
            catch exception
                % In case of error show it and revert the change
                uialert(app.LiveDataAcquisitionUIFigure, exception.message, 'Start error');   
                setAppViewState(app, 'configuration'); 
            end
            
            % Clear Log status text
            app.LogStatusText.Text = '';

        end

        % Button pushed function: StopButton
        function StopButtonPushed(app, ~)

            setAppViewState(app, 'filesave');
            stop(app.DAQ);

            if app.LogRequested
                % Log data to file switch is on
                % Save logged data to MAT file (unless the user clicks Cancel in the "Save As" dialog)
                
                % Close temporary binary file
                fclose(app.TempFile);
                
                
                % Gather metadata in preparation for saving to MAT file
                % Store relevant Daq device info
                deviceInfo = get(app.DevicesInfo(app.DeviceDropDown.Value-1));
                deviceInfo.Vendor = get(deviceInfo.Vendor);
                deviceInfo = rmfield(deviceInfo, 'Subsystems');
                metadata.DeviceInfo = deviceInfo;
                metadata.Channel1 = app.Channel1DropDown.Value;
                metadata.Channel2 = app.Channel2DropDown.Value;
                metadata.MeasurementType = app.MeasurementTypeDropDown.Value;
                metadata.Range = app.RangeDropDown.Value;
                metadata.Coupling = app.CouplingDropDown.Value;
                metadata.TerminalConfig = app.TerminalConfigDropDown.Value;
                metadata.ExcitationSource = app.ExcitationSourceDropDown.Value;
                metadata.Rate = app.RateEdit.Value;
                metadata.TriggerTime = datetime(app.TriggerTime, 'ConvertFrom', 'datenum', 'TimeZone', 'local');
                
                % Open "Save As" to request destination MAT file path and file name from user
                [filename, pathname] = uiputfile({'*.mat'}, 'Save as',...
                    fullfile(app.Filepath, app.Filename));
                
                if ~(isequal(filename,0) || isequal(pathname,0))
                    % User specified a file name in a folder with write permission
                    app.Filename = filename;
                    app.Filepath = pathname;
                    cancelSaveAs = false;
                else
                    %  User clicked Cancel in "Save As" dialog
                    cancelSaveAs = true;
                end
                
                if ~cancelSaveAs
                    % Convert data from binary file to MAT file
                    matFilepath = fullfile(app.Filepath, app.Filename);
                    app.LogStatusText.Text = 'Saving data to MAT file is in progress...';
                    drawnow
                    
                    numColumns = 3;
                    binFile2MAT(app, app.TempFilename, matFilepath, numColumns, metadata);
                    app.LogStatusText.Text = sprintf('Saving data to ''%s'' file has completed.', app.Filename);
                    
                else
                    % User clicked Cancel in "Save As" dialog
                    % Inform user that data has not been saved
                    app.LogStatusText.Text = 'Saving data to MAT file was cancelled.';
                end
            end
            
            % Enable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(app, 'configuration');
        end

        % Value changed function: Channel1DropDown
        function Channel1DropDownValueChanged(app, ~)
            
            updateChannelMeasurementComponents(app)
            
        end

        % Value changed function: Channel1DropDown
        function Channel2DropDownValueChanged(app, ~)
            
            updateChannelMeasurementComponents(app)
            
        end

        % Value changed function: CouplingDropDown, 
        % ...and 3 other components
        function ChannelPropertyValueChanged(app, event)
            % Shared callback for RangeDropDown, TerminalConfigDropDown, CouplingDropDown, and ExcitationSourceDropDown
            
            % This executes only for 'Voltage' measurement type, since for 'Audio' measurement
            % type Range never changes, and TerminalConfig and Coupling are disabled.
            
            value = event.Source.Value;
            
            % Set channel property to selected value
            % The channel property name was previously stored in the UI component Tag
            propertyName = event.Source.Tag;
            try
                set(app.DAQ.Channels(1), propertyName, value);
            catch exception
                % In case of error show it and revert the change
                uialert(app.LiveDataAcquisitionUIFigure, exception.message, 'Channel property error');
                event.Source.Value = event.PreviousValue;
            end
            
            % Make sure shown channel property values are not stale, as some property update can trigger changes in other properties
            % Update UI with current channel property values from data acquisition object
            currentRange = app.DAQ.Channels(1).Range;
            app.RangeDropDown.Value = [currentRange.Min currentRange.Max];
            app.TerminalConfigDropDown.Value = app.DAQ.Channels(1).TerminalConfig;
            app.CouplingDropDown.Value = app.DAQ.Channels(1).Coupling;
            
        end

        % Value changing function: RateSlider
        function RateSliderValueChanging(app, event)
            changingValue = event.Value;
            app.RateEdit.Value = changingValue;
        end

        % Value changed function: RateEdit, RateSlider
        function RateSliderValueChanged(app, event)
            % Shared callback for RateSlider and RateEdit
            
            value = event.Source.Value;
            if ~isempty(app.DAQ)
                app.DAQ.Rate = value;
                
                % Update UI with current rate and time window limits
                updateRateUIComponents(app)
                
            end
        end

        % Value changed function: YmaxEditField, YminEditField
        function YmaxminValueChanged(app, event)
            % Shared callback for YmaxEditField and YminEditField
            
            ymin = app.YminEditField.Value;
            ymax = app.YmaxEditField.Value;
            if ymax>ymin
                ylim(app.LiveAxes, [ymin, ymax]);
            else
                % If new limits are not correct, revert the change
                event.Source.Value = event.PreviousValue;
            end
        end

        % Value changed function: AutoscaleYSwitch
        function AutoscaleYSwitchValueChanged(app, ~)
            updateAutoscaleYSwitchComponents(app)
        end

        % Value changed function: LogdatatofileSwitch
        function LogdatatofileSwitchValueChanged(app, ~)
            updateLogdatatofileSwitchComponents(app)
        end

        % Close request function: LiveDataAcquisitionUIFigure
        function LiveDataAcquisitionCloseRequest(app, ~)
            
            isAcquiring = ~isempty(app.DAQ) && app.DAQ.Running;
            if isAcquiring
                question = 'Abort acquisition and close app?';
                
            else
                % Acquisition is stopped
                question = 'Close app?';
            end
            
            uiconfirm(app.LiveDataAcquisitionUIFigure,question,'Confirm Close',...
                'CloseFcn',@(src,event) closeApp_Callback(app,src,event,isAcquiring));
            
        end

        % Value changed function: MeasurementTypeDropDown
        function MeasurementTypeDropDownValueChanged(app, ~)
            
            updateChannelMeasurementComponents(app)

        end
    end

    % Component initialization
    methods (Access = private)

        % Create UIFigure and components
        function createComponents(app)

            % Create LiveDataAcquisitionUIFigure and hide until all components are created
            app.LiveDataAcquisitionUIFigure = uifigure('Visible', 'off');
            app.LiveDataAcquisitionUIFigure.Position = [100 100 908 602];
            app.LiveDataAcquisitionUIFigure.Name = 'Live Data Acquisition';
            app.LiveDataAcquisitionUIFigure.CloseRequestFcn = createCallbackFcn(app, @LiveDataAcquisitionCloseRequest, true);

            % Create AcquisitionPanel
            app.AcquisitionPanel = uipanel(app.LiveDataAcquisitionUIFigure);
            app.AcquisitionPanel.Position = [282 498 613 89];

            % Create StartButton
            app.StartButton = uibutton(app.AcquisitionPanel, 'push');
            app.StartButton.ButtonPushedFcn = createCallbackFcn(app, @StartButtonPushed, true);
            app.StartButton.BackgroundColor = [0.4706 0.6706 0.1882];
            app.StartButton.FontSize = 14;
            app.StartButton.FontColor = [1 1 1];
            app.StartButton.Position = [341 32 100 24];
            app.StartButton.Text = 'Start';

            % Create StopButton
            app.StopButton = uibutton(app.AcquisitionPanel, 'push');
            app.StopButton.ButtonPushedFcn = createCallbackFcn(app, @StopButtonPushed, true);
            app.StopButton.BackgroundColor = [0.6392 0.0784 0.1804];
            app.StopButton.FontSize = 14;
            app.StopButton.FontColor = [1 1 1];
            app.StopButton.Position = [462 32 100 24];
            app.StopButton.Text = 'Stop';

            % Create LogdatatofileSwitchLabel
            app.LogdatatofileSwitchLabel = uilabel(app.AcquisitionPanel);
            app.LogdatatofileSwitchLabel.HorizontalAlignment = 'center';
            app.LogdatatofileSwitchLabel.Position = [50 33 84 22];
            app.LogdatatofileSwitchLabel.Text = 'Log data to file';

            % Create LogdatatofileSwitch
            app.LogdatatofileSwitch = uiswitch(app.AcquisitionPanel, 'slider');
            app.LogdatatofileSwitch.ValueChangedFcn = createCallbackFcn(app, @LogdatatofileSwitchValueChanged, true);
            app.LogdatatofileSwitch.Position = [165 34 45 20];

            % Create LogStatusText
            app.LogStatusText = uilabel(app.AcquisitionPanel);
            app.LogStatusText.Position = [54 6 532 22];
            app.LogStatusText.Text = '';

            % Create DevicePanel
            app.DevicePanel = uipanel(app.LiveDataAcquisitionUIFigure);
            app.DevicePanel.Position = [21 19 250 469];

            % Create Channel1DropDownLabel
            app.Channel1DropDownLabel = uilabel(app.DevicePanel);
            app.Channel1DropDownLabel.HorizontalAlignment = 'right';
            app.Channel1DropDownLabel.Position = [63 391 60 22];
            app.Channel1DropDownLabel.Text = 'Channel 1';

            % Create Channel1DropDown
            app.Channel1DropDown = uidropdown(app.DevicePanel);
            app.Channel1DropDown.Items = {};
            app.Channel1DropDown.ValueChangedFcn = createCallbackFcn(app, @Channel1DropDownValueChanged, true);
            app.Channel1DropDown.Position = [129 391 100 22];
            app.Channel1DropDown.Value = {};

            % Create Channel2DropDownLabel
            app.Channel2DropDownLabel = uilabel(app.DevicePanel);
            app.Channel2DropDownLabel.HorizontalAlignment = 'right';
            app.Channel2DropDownLabel.Position = [63 356 60 22];
            app.Channel2DropDownLabel.Text = 'Channel 2';

            % Create Channel2DropDown
            app.Channel2DropDown = uidropdown(app.DevicePanel);
            app.Channel2DropDown.Items = {};
            app.Channel2DropDown.Position = [129 356 100 22];
            app.Channel2DropDown.Value = {};

            % Create MeasurementTypeDropDownLabel
            app.MeasurementTypeDropDownLabel = uilabel(app.DevicePanel);
            app.MeasurementTypeDropDownLabel.HorizontalAlignment = 'right';
            app.MeasurementTypeDropDownLabel.Position = [15 308 110 22];
            app.MeasurementTypeDropDownLabel.Text = 'Measurement Type';

            % Create MeasurementTypeDropDown
            app.MeasurementTypeDropDown = uidropdown(app.DevicePanel);
            app.MeasurementTypeDropDown.Items = {};
            app.MeasurementTypeDropDown.ValueChangedFcn = createCallbackFcn(app, @MeasurementTypeDropDownValueChanged, true);
            app.MeasurementTypeDropDown.Position = [131 308 100 22];
            app.MeasurementTypeDropDown.Value = {};

            % Create RangeDropDownLabel
            app.RangeDropDownLabel = uilabel(app.DevicePanel);
            app.RangeDropDownLabel.HorizontalAlignment = 'right';
            app.RangeDropDownLabel.Position = [84 274 41 22];
            app.RangeDropDownLabel.Text = 'Range';

            % Create RangeDropDown
            app.RangeDropDown = uidropdown(app.DevicePanel);
            app.RangeDropDown.Items = {};
            app.RangeDropDown.ValueChangedFcn = createCallbackFcn(app, @ChannelPropertyValueChanged, true);
            app.RangeDropDown.Position = [131 274 100 22];
            app.RangeDropDown.Value = {};

            % Create TerminalConfigDropDownLabel
            app.TerminalConfigDropDownLabel = uilabel(app.DevicePanel);
            app.TerminalConfigDropDownLabel.HorizontalAlignment = 'right';
            app.TerminalConfigDropDownLabel.Position = [33 207 92 22];
            app.TerminalConfigDropDownLabel.Text = 'Terminal Config.';

            % Create TerminalConfigDropDown
            app.TerminalConfigDropDown = uidropdown(app.DevicePanel);
            app.TerminalConfigDropDown.Items = {};
            app.TerminalConfigDropDown.ValueChangedFcn = createCallbackFcn(app, @ChannelPropertyValueChanged, true);
            app.TerminalConfigDropDown.Position = [131 207 100 22];
            app.TerminalConfigDropDown.Value = {};

            % Create CouplingDropDownLabel
            app.CouplingDropDownLabel = uilabel(app.DevicePanel);
            app.CouplingDropDownLabel.HorizontalAlignment = 'right';
            app.CouplingDropDownLabel.Position = [72 240 53 22];
            app.CouplingDropDownLabel.Text = 'Coupling';

            % Create CouplingDropDown
            app.CouplingDropDown = uidropdown(app.DevicePanel);
            app.CouplingDropDown.Items = {};
            app.CouplingDropDown.ValueChangedFcn = createCallbackFcn(app, @ChannelPropertyValueChanged, true);
            app.CouplingDropDown.Position = [131 240 100 22];
            app.CouplingDropDown.Value = {};

            % Create DeviceDropDownLabel
            app.DeviceDropDownLabel = uilabel(app.DevicePanel);
            app.DeviceDropDownLabel.HorizontalAlignment = 'right';
            app.DeviceDropDownLabel.Position = [21 425 42 22];
            app.DeviceDropDownLabel.Text = 'Device';

            % Create DeviceDropDown
            app.DeviceDropDown = uidropdown(app.DevicePanel);
            app.DeviceDropDown.Items = {'Detecting devices...'};
            app.DeviceDropDown.ValueChangedFcn = createCallbackFcn(app, @DeviceDropDownValueChanged, true);
            app.DeviceDropDown.Position = [69 425 160 22];
            app.DeviceDropDown.Value = 'Detecting devices...';

            % Create RateEdit
            app.RateEdit = uieditfield(app.DevicePanel, 'numeric');
            app.RateEdit.Limits = [1e-06 10000000];
            app.RateEdit.ValueDisplayFormat = '%.1f';
            app.RateEdit.ValueChangedFcn = createCallbackFcn(app, @RateSliderValueChanged, true);
            app.RateEdit.Position = [123 106 100 22];
            app.RateEdit.Value = 1000;

            % Create RatescanssSliderLabel
            app.RatescanssSliderLabel = uilabel(app.DevicePanel);
            app.RatescanssSliderLabel.HorizontalAlignment = 'right';
            app.RatescanssSliderLabel.Position = [28 106 83 22];
            app.RatescanssSliderLabel.Text = 'Rate (scans/s)';

            % Create RateSlider
            app.RateSlider = uislider(app.DevicePanel);
            app.RateSlider.Limits = [1e-06 1000];
            app.RateSlider.ValueChangedFcn = createCallbackFcn(app, @RateSliderValueChanged, true);
            app.RateSlider.ValueChangingFcn = createCallbackFcn(app, @RateSliderValueChanging, true);
            app.RateSlider.Position = [71 95 150 3];
            app.RateSlider.Value = 1000;

            % Create ExcitationSourceDropDownLabel
            app.ExcitationSourceDropDownLabel = uilabel(app.DevicePanel);
            app.ExcitationSourceDropDownLabel.HorizontalAlignment = 'right';
            app.ExcitationSourceDropDownLabel.Position = [25 174 100 22];
            app.ExcitationSourceDropDownLabel.Text = 'Excitation Source';

            % Create ExcitationSourceDropDown
            app.ExcitationSourceDropDown = uidropdown(app.DevicePanel);
            app.ExcitationSourceDropDown.Items = {};
            app.ExcitationSourceDropDown.ValueChangedFcn = createCallbackFcn(app, @ChannelPropertyValueChanged, true);
            app.ExcitationSourceDropDown.Position = [131 174 100 22];
            app.ExcitationSourceDropDown.Value = {};

            % Create LiveDataAcquisitionLabel
            app.LiveDataAcquisitionLabel = uilabel(app.LiveDataAcquisitionUIFigure);
            app.LiveDataAcquisitionLabel.FontSize = 24;
            app.LiveDataAcquisitionLabel.Position = [27 527 232 30];
            app.LiveDataAcquisitionLabel.Text = 'Live Data Acquisition';

            % Create LiveViewPanel
            app.LiveViewPanel = uipanel(app.LiveDataAcquisitionUIFigure);
            app.LiveViewPanel.Position = [282 19 613 469];

            % Create LiveAxes
            app.LiveAxes = uiaxes(app.LiveViewPanel);
            xlabel(app.LiveAxes, 'Time (s)')
            ylabel(app.LiveAxes, 'Voltage (V)')
            app.LiveAxes.XTickLabelRotation = 0;
            app.LiveAxes.YTickLabelRotation = 0;
            app.LiveAxes.ZTickLabelRotation = 0;
            app.LiveAxes.Position = [6 8 602 423];

            % Create AutoscaleYSwitchLabel
            app.AutoscaleYSwitchLabel = uilabel(app.LiveViewPanel);
            app.AutoscaleYSwitchLabel.HorizontalAlignment = 'center';
            app.AutoscaleYSwitchLabel.Position = [9 440 70 22];
            app.AutoscaleYSwitchLabel.Text = 'Autoscale Y';

            % Create AutoscaleYSwitch
            app.AutoscaleYSwitch = uiswitch(app.LiveViewPanel, 'slider');
            app.AutoscaleYSwitch.ValueChangedFcn = createCallbackFcn(app, @AutoscaleYSwitchValueChanged, true);
            app.AutoscaleYSwitch.Position = [102 441 45 20];
            app.AutoscaleYSwitch.Value = 'On';

            % Create YminEditFieldLabel
            app.YminEditFieldLabel = uilabel(app.LiveViewPanel);
            app.YminEditFieldLabel.HorizontalAlignment = 'right';
            app.YminEditFieldLabel.Position = [186 440 33 22];
            app.YminEditFieldLabel.Text = 'Ymin';

            % Create YminEditField
            app.YminEditField = uieditfield(app.LiveViewPanel, 'numeric');
            app.YminEditField.ValueChangedFcn = createCallbackFcn(app, @YmaxminValueChanged, true);
            app.YminEditField.Position = [226 440 52 22];
            app.YminEditField.Value = -1;

            % Create YmaxEditFieldLabel
            app.YmaxEditFieldLabel = uilabel(app.LiveViewPanel);
            app.YmaxEditFieldLabel.HorizontalAlignment = 'right';
            app.YmaxEditFieldLabel.Position = [291 440 36 22];
            app.YmaxEditFieldLabel.Text = 'Ymax';

            % Create YmaxEditField
            app.YmaxEditField = uieditfield(app.LiveViewPanel, 'numeric');
            app.YmaxEditField.ValueChangedFcn = createCallbackFcn(app, @YmaxminValueChanged, true);
            app.YmaxEditField.Position = [334 440 52 22];
            app.YmaxEditField.Value = 1;

            % Create TimewindowsEditFieldLabel
            app.TimewindowsEditFieldLabel = uilabel(app.LiveViewPanel);
            app.TimewindowsEditFieldLabel.HorizontalAlignment = 'right';
            app.TimewindowsEditFieldLabel.Position = [444 440 92 22];
            app.TimewindowsEditFieldLabel.Text = 'Time window (s)';

            % Create TimewindowEditField
            app.TimewindowEditField = uieditfield(app.LiveViewPanel, 'numeric');
            app.TimewindowEditField.Position = [540 440 56 22];
            app.TimewindowEditField.Value = 1;

            % Show the figure after all components are created
            app.LiveDataAcquisitionUIFigure.Visible = 'on';
        end
    end

    % App creation and deletion
    methods (Access = public)

        % Construct app
        function app = LiveDataAppBasic

            % Create UIFigure and components
            createComponents(app)

            % Register the app with App Designer
            registerApp(app, app.LiveDataAcquisitionUIFigure)

            % Execute the startup function
            runStartupFcn(app, @startupFcn)

            if nargout == 0
                clear app
            end
        end

        % Code that executes before app deletion
        function delete(app)

            % Delete UIFigure when app is deleted
            delete(app.LiveDataAcquisitionUIFigure)
        end
    end
end