classdef ChannelDashboard
    %CHANNELDASHBOARD Summary of this class goes here
    %   Detailed explanation goes here
    
    properties (Access = public)
        LiveDataAcquisitionUIFigure    matlab.ui.Figure
        LiveViewPanel                  matlab.ui.container.Panel
        LiveAxes                       matlab.ui.control.UIAxes
        YmaxEditField                  matlab.ui.control.NumericEditField
        YmaxEditFieldLabel             matlab.ui.control.Label
        YminEditField                  matlab.ui.control.NumericEditField
        YminEditFieldLabel             matlab.ui.control.Label
        AutoscaleYSwitch               matlab.ui.control.Switch
        AutoscaleYSwitchLabel          matlab.ui.control.Label
        LiveDataAcquisitionLabel       matlab.ui.control.Label
        DevicePanel                    matlab.ui.container.Panel
        ExcitationSourceDropDown       matlab.ui.control.DropDown
        ExcitationSourceDropDownLabel  matlab.ui.control.Label
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
        ChannelDropDown                matlab.ui.control.DropDown
        ChannelDropDownLabel           matlab.ui.control.Label
    end

    properties (Access = private)
        DAQMeasurementTypes = {'Voltage','IEPE','Audio'};  % DAQ input measurement types supported by the app
        DAQSubsystemTypes = {'AnalogInput','AudioInput'};  % DAQ subsystem types supported by the app
        DevicesInfo           % Array of devices that provide analog input voltage or audio input measurements
        DataFIFOBuffer        % Data FIFO buffer used for live plot of latest "N" seconds of acquired data
        LivePlotLine          % Handle to line plot of acquired data
        TriggerTime           % Acquisition start time stored as datetime
        MeasurementType       % Handle to the specified measurement type
    end
    
    
    methods (Access = private)
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
        
        
        function setAppViewState(cd, state)
        %setAppViewState Sets the app in a new state and enables/disables corresponding components
        %  state can be 'deviceselection', 'configuration', 'acquisition', or 'filesave'
        
            switch state                
                case 'deviceselection'
                    cd.DeviceDropDown.Enable = 'on';
                    cd.ChannelDropDown.Enable = 'off';
                    cd.MeasurementTypeDropDown.Enable = 'off';
                    cd.RangeDropDown.Enable = 'off';
                    cd.TerminalConfigDropDown.Enable = 'off';
                    cd.CouplingDropDown.Enable = 'off';
                    cd.ExcitationSourceDropDown.Enable = 'off';
                    cd.TimewindowEditField.Enable = 'off';
                case 'configuration'
                    cd.DeviceDropDown.Enable = 'on';
                    cd.ChannelDropDown.Enable = 'on';
                    cd.MeasurementTypeDropDown.Enable = 'on';
                    cd.RangeDropDown.Enable = 'on';
                    cd.TimewindowEditField.Enable = 'on';

                    switch cd.MeasurementTypeDropDown.Value
                        case 'Voltage'
                            % Voltage channels do not have ExcitationSource
                            % property, so disable the corresponding UI controls
                            cd.TerminalConfigDropDown.Enable = 'on';
                            cd.CouplingDropDown.Enable = 'on';
                            cd.ExcitationSourceDropDown.Enable = 'off';
                        case 'Audio'
                            % Audio channels do not have TerminalConfig, Coupling, and ExcitationSource
                            % properties, so disable the corresponding UI controls
                            cd.TerminalConfigDropDown.Enable = 'off';
                            cd.CouplingDropDown.Enable = 'off';
                            cd.ExcitationSourceDropDown.Enable = 'off';
                        case 'IEPE'
                            cd.TerminalConfigDropDown.Enable = 'on';
                            cd.CouplingDropDown.Enable = 'on';
                            cd.ExcitationSourceDropDown.Enable = 'on';
                    end
                case 'acquisition'
                    cd.DeviceDropDown.Enable = 'off';
                    cd.ChannelDropDown.Enable = 'off';
                    cd.MeasurementTypeDropDown.Enable = 'off';
                    cd.RangeDropDown.Enable = 'off';
                    cd.TerminalConfigDropDown.Enable = 'off';
                    cd.CouplingDropDown.Enable = 'off';
                    cd.ExcitationSourceDropDown.Enable = 'off';
                    cd.TimewindowEditField.Enable = 'on';
                    updateLogdatatofileSwitchComponents(cd)
                case 'filesave'
                    cd.DeviceDropDown.Enable = 'off';
                    cd.ChannelDropDown.Enable = 'off';
                    cd.MeasurementTypeDropDown.Enable = 'off';
                    cd.RangeDropDown.Enable = 'off';
                    cd.TerminalConfigDropDown.Enable = 'off';
                    cd.CouplingDropDown.Enable = 'off';
                    cd.ExcitationSourceDropDown.Enable = 'off';
                    cd.TimewindowEditField.Enable = 'on';
                    updateLogdatatofileSwitchComponents(cd)   
            end
        end
        
        function closeApp_Callback(cd, ~, event)
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
                    cd.LiveDataAcquisitionUIFigure.Visible = 'off';
                case 'Cancel'
                    % Continue
            end
            
        end
        
        function updateAutoscaleYSwitchComponents(cd)
        %updateAutoscaleYSwitchComponents Updates UI components related to y-axis autoscale
        
            value = cd.AutoscaleYSwitch.Value;
            switch value
                case 'Off'
                    cd.YminEditField.Enable = 'on';
                    cd.YmaxEditField.Enable = 'on';
                    YmaxminValueChanged(cd, []);
                case 'On'
                    cd.YminEditField.Enable = 'off';
                    cd.YmaxEditField.Enable = 'off';
                    cd.LiveAxes.YLimMode = 'auto';
            end
        end
        
        function updateChannelMeasurementComponents(cd)
        %updateChannelMeasurementComponents Updates channel properties and measurement UI components
            measurementType = cd.MeasurementTypeDropDown.Value;

            % Get selected DAQ device index (to be used with DaqDevicesInfo list)
            deviceIndex = cd.DeviceDropDown.Value - 1;
                        
            % Get DAQ subsystem information (analog input or audio input)
            % Analog input or analog output subsystems are the first subsystem of the device
            subsystem = cd.DevicesInfo(deviceIndex).Subsystems(1);
                         
            % Only 'Voltage', 'IEPE' and 'Audio' measurement types are supported in this version of the app
            % Depending on what type of device is selected, populate the UI elements channel properties
            switch subsystem.SubsystemType
                case 'AnalogInput'                                       
                    % Populate dropdown with available channel 'TerminalConfig' options
                    cd.TerminalConfigDropDown.Items = getChannelPropertyOptions(cd, subsystem, 'TerminalConfig');
                    % Update UI with the actual channel property value
                    % (default value is not necessarily first in the list)
                    % DropDown Value must be set as a character array in MATLAB R2017b
                    cd.TerminalConfigDropDown.Value = d.Channels(1).TerminalConfig;
                    cd.TerminalConfigDropDown.Tag = 'TerminalConfig';
                    
                    % Populate dropdown with available channel 'Coupling' options
                    cd.CouplingDropDown.Items =  getChannelPropertyOptions(cd, subsystem, 'Coupling');
                    % Update UI with the actual channel property value
                    cd.CouplingDropDown.Value = d.Channels(1).Coupling;
                    cd.CouplingDropDown.Tag = 'Coupling';
                                        
                    % Populate dropdown with available channel 'ExcitationSource' options
                    if strcmpi(measurementType, 'IEPE')
                        cd.ExcitationSourceDropDown.Items = getChannelPropertyOptions(cd, subsystem, 'ExcitationSource');
                        cd.ExcitationSourceDropDown.Value = d.Channels(1).ExcitationSource;
                        cd.ExcitationSourceDropDown.Tag = 'ExcitationSource';
                    else
                        cd.ExcitationSourceDropDown.Items = {''};
                    end
                    
                    ylabel(cd.LiveAxes, 'Voltage (V)')
                                        
                case 'AudioInput'
                    ylabel(cd.LiveAxes, 'Normalized amplitude')
            end
            
            % Populate dropdown with available 'Range' options
            [rangeItems, rangeItemsData] = getChannelPropertyOptions(cd, subsystem, 'Range');
            cd.RangeDropDown.Items = rangeItems;
            cd.RangeDropDown.ItemsData = rangeItemsData;
            
            % Update UI with current channel 'Range'
            currentRange = d.Channels(1).Range;
            cd.RangeDropDown.Value = [currentRange.Min currentRange.Max];
            cd.RangeDropDown.Tag = 'Range';
            
            cd.DeviceDropDown.Items{1} = 'Deselect device';
            
            % Enable DAQ device, channel properties, and start acquisition UI components
            setAppViewState(cd, 'configuration');
        end
    end

    % Callbacks that handle component events
    methods (Access = private)

        % Value changed function: DeviceDropDown
        function DeviceDropDownValueChanged(cd, app, event)
            value = cd.DeviceDropDown.Value;
            
            if ~isempty(value)
                % Device index is offset by 1 because first element in device dropdown
                % is "Select a device" (not a device).
                deviceIndex = value-1 ;
                
                % Reset channel property options
                cd.ChannelDropDown.Items = {''};
                cd.MeasurementTypeDropDown.Items = {''};
                cd.RangeDropDown.Items = {''};
                cd.TerminalConfigDropDown.Items = {''};
                cd.CouplingDropDown.Items = {''};
                cd.ExcitationSourceDropDown.Items = {''};
                setAppViewState(cd, 'deviceselection');
                
                if deviceIndex > 0
                    % If a device is selected
                    
                    % Get subsystem information to update channel dropdown list and channel property options
                    % For devices that have an analog input or an audio input subsystem, this is the first subsystem
                    subsystem = cd.DevicesInfo(deviceIndex).Subsystems(1);
                    cd.ChannelDropDown.Items = cellstr(string(subsystem.ChannelNames));
                                        
                    % Populate available measurement types for the selected device
                    cd.MeasurementTypeDropDown.Items = intersect(cd.DAQMeasurementTypes,...
                                subsystem.MeasurementTypesAvailable, 'stable');

                    % Update channel and channel property options
                    updateChannelMeasurementComponents(cd)

                else
                    % If no device is selected

                    % Delete existing data acquisition object
                    delete(app.DAQ);
                    app.DAQ = [];
                    
                    cd.DeviceDropDown.Items{1} = 'Select a device';

                    setAppViewState(cd, 'deviceselection');
                end
            end
        end

        % Value changed function: ChannelDropDown
        function ChannelDropDownValueChanged(cd, event)
            
            updateChannelMeasurementComponents(cd)
            
        end

        % Value changed function: CouplingDropDown, 
        % ...and 3 other components
        function ChannelPropertyValueChanged(cd, app, event)
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
                uialert(cd.LiveDataAcquisitionUIFigure, exception.message, 'Channel property error');
                event.Source.Value = event.PreviousValue;
            end
            
            % Make sure shown channel property values are not stale, as some property update can trigger changes in other properties
            % Update UI with current channel property values from data acquisition object
            currentRange = app.DAQ.Channels(1).Range;
            cd.RangeDropDown.Value = [currentRange.Min currentRange.Max];
            cd.TerminalConfigDropDown.Value = app.DAQ.Channels(1).TerminalConfig;
            cd.CouplingDropDown.Value = app.DAQ.Channels(1).Coupling;
            
        end

        % Value changed function: YmaxEditField, YminEditField
        function YmaxminValueChanged(cd, event)
            % Shared callback for YmaxEditField and YminEditField
            
            ymin = cd.YminEditField.Value;
            ymax = cd.YmaxEditField.Value;
            if ymax>ymin
                ylim(cd.LiveAxes, [ymin, ymax]);
            else
                % If new limits are not correct, revert the change
                event.Source.Value = event.PreviousValue;
            end
        end

        % Value changed function: AutoscaleYSwitch
        function AutoscaleYSwitchValueChanged(cd, event)
            updateAutoscaleYSwitchComponents(cd)
        end

        % Close request function: LiveDataAcquisitionUIFigure
        function LiveDataAcquisitionCloseRequest(cd, app, event)
            
            isAcquiring = ~isempty(app.DAQ) && app.DAQ.Running;
            if isAcquiring
                question = 'Abort acquisition and close app?';
                
            else
                % Acquisition is stopped
                question = 'Close app?';
            end
            
            uiconfirm(cd.LiveDataAcquisitionUIFigure,question,'Confirm Close',...
                'CloseFcn',@(src,event) closeApp_Callback(cd,src,event,isAcquiring));
            
        end

        % Value changed function: MeasurementTypeDropDown
        function MeasurementTypeDropDownValueChanged(cd, event)
            
            updateChannelMeasurementComponents(cd)

        end
    end

    % Initialization helper functions
    methods (Access = private)

        % Create UIFigure and components
        function cd = createComponents(cd)

            % Create LiveDataAcquisitionUIFigure and hide until all components are created
            cd.LiveDataAcquisitionUIFigure = uifigure('Visible', 'off');
            cd.LiveDataAcquisitionUIFigure.Position = [100 100 908 602];
            cd.LiveDataAcquisitionUIFigure.Name = 'Live Data Acquisition';
%             cd.LiveDataAcquisitionUIFigure.CloseRequestFcn = createCallbackFcn(cd, @LiveDataAcquisitionCloseRequest, true);

            % Create DevicePanel
            cd.DevicePanel = uipanel(cd.LiveDataAcquisitionUIFigure);
            cd.DevicePanel.Position = [21 19 250 469];

            % Create Channel1DropDownLabel
            cd.ChannelDropDownLabel = uilabel(cd.DevicePanel);
            cd.ChannelDropDownLabel.HorizontalAlignment = 'right';
            cd.ChannelDropDownLabel.Position = [63 391 60 22];
            cd.ChannelDropDownLabel.Text = 'Channel 1';

            % Create Channel1DropDown
            cd.ChannelDropDown = uidropdown(cd.DevicePanel);
            cd.ChannelDropDown.Items = {};
%             cd.ChannelDropDown.ValueChangedFcn = createCallbackFcn(cd, @Channel1DropDownValueChanged, true);
            cd.ChannelDropDown.Position = [129 391 100 22];
            cd.ChannelDropDown.Value = {};

            % Create MeasurementTypeDropDownLabel
            cd.MeasurementTypeDropDownLabel = uilabel(cd.DevicePanel);
            cd.MeasurementTypeDropDownLabel.HorizontalAlignment = 'right';
            cd.MeasurementTypeDropDownLabel.Position = [15 308 110 22];
            cd.MeasurementTypeDropDownLabel.Text = 'Measurement Type';

            % Create MeasurementTypeDropDown
            cd.MeasurementTypeDropDown = uidropdown(cd.DevicePanel);
            cd.MeasurementTypeDropDown.Items = {};
            cd.MeasurementTypeDropDown.ValueChangedFcn = createCallbackFcn(cd, @MeasurementTypeDropDownValueChanged, true);
            cd.MeasurementTypeDropDown.Position = [131 308 100 22];
            cd.MeasurementTypeDropDown.Value = {};

            % Create RangeDropDownLabel
            cd.RangeDropDownLabel = uilabel(cd.DevicePanel);
            cd.RangeDropDownLabel.HorizontalAlignment = 'right';
            cd.RangeDropDownLabel.Position = [84 274 41 22];
            cd.RangeDropDownLabel.Text = 'Range';

            % Create RangeDropDown
            cd.RangeDropDown = uidropdown(cd.DevicePanel);
            cd.RangeDropDown.Items = {};
            cd.RangeDropDown.ValueChangedFcn = createCallbackFcn(cd, @ChannelPropertyValueChanged, true);
            cd.RangeDropDown.Position = [131 274 100 22];
            cd.RangeDropDown.Value = {};

            % Create TerminalConfigDropDownLabel
            cd.TerminalConfigDropDownLabel = uilabel(cd.DevicePanel);
            cd.TerminalConfigDropDownLabel.HorizontalAlignment = 'right';
            cd.TerminalConfigDropDownLabel.Position = [33 207 92 22];
            cd.TerminalConfigDropDownLabel.Text = 'Terminal Config.';

            % Create TerminalConfigDropDown
            cd.TerminalConfigDropDown = uidropdown(cd.DevicePanel);
            cd.TerminalConfigDropDown.Items = {};
            cd.TerminalConfigDropDown.ValueChangedFcn = createCallbackFcn(cd, @ChannelPropertyValueChanged, true);
            cd.TerminalConfigDropDown.Position = [131 207 100 22];
            cd.TerminalConfigDropDown.Value = {};

            % Create CouplingDropDownLabel
            cd.CouplingDropDownLabel = uilabel(cd.DevicePanel);
            cd.CouplingDropDownLabel.HorizontalAlignment = 'right';
            cd.CouplingDropDownLabel.Position = [72 240 53 22];
            cd.CouplingDropDownLabel.Text = 'Coupling';

            % Create CouplingDropDown
            cd.CouplingDropDown = uidropdown(cd.DevicePanel);
            cd.CouplingDropDown.Items = {};
            cd.CouplingDropDown.ValueChangedFcn = createCallbackFcn(cd, @ChannelPropertyValueChanged, true);
            cd.CouplingDropDown.Position = [131 240 100 22];
            cd.CouplingDropDown.Value = {};

            % Create DeviceDropDownLabel
            cd.DeviceDropDownLabel = uilabel(cd.DevicePanel);
            cd.DeviceDropDownLabel.HorizontalAlignment = 'right';
            cd.DeviceDropDownLabel.Position = [21 425 42 22];
            cd.DeviceDropDownLabel.Text = 'Device';

            % Create DeviceDropDown
            cd.DeviceDropDown = uidropdown(cd.DevicePanel);
            cd.DeviceDropDown.Items = {'Detecting devices...'};
            cd.DeviceDropDown.ValueChangedFcn = createCallbackFcn(cd, @DeviceDropDownValueChanged, true);
            cd.DeviceDropDown.Position = [69 425 160 22];
            cd.DeviceDropDown.Value = 'Detecting devices...';

            % Create ExcitationSourceDropDownLabel
            cd.ExcitationSourceDropDownLabel = uilabel(cd.DevicePanel);
            cd.ExcitationSourceDropDownLabel.HorizontalAlignment = 'right';
            cd.ExcitationSourceDropDownLabel.Position = [25 174 100 22];
            cd.ExcitationSourceDropDownLabel.Text = 'Excitation Source';

            % Create ExcitationSourceDropDown
            cd.ExcitationSourceDropDown = uidropdown(cd.DevicePanel);
            cd.ExcitationSourceDropDown.Items = {};
            cd.ExcitationSourceDropDown.ValueChangedFcn = createCallbackFcn(cd, @ChannelPropertyValueChanged, true);
            cd.ExcitationSourceDropDown.Position = [131 174 100 22];
            cd.ExcitationSourceDropDown.Value = {};

            % Create LiveDataAcquisitionLabel
            cd.LiveDataAcquisitionLabel = uilabel(cd.LiveDataAcquisitionUIFigure);
            cd.LiveDataAcquisitionLabel.FontSize = 24;
            cd.LiveDataAcquisitionLabel.Position = [27 527 232 30];
            cd.LiveDataAcquisitionLabel.Text = 'Live Data Acquisition';

            % Create LiveViewPanel
            cd.LiveViewPanel = uipanel(cd.LiveDataAcquisitionUIFigure);
            cd.LiveViewPanel.Position = [282 19 613 469];

            % Create LiveAxes
            cd.LiveAxes = uiaxes(cd.LiveViewPanel);
            xlabel(cd.LiveAxes, 'Time (s)')
            ylabel(cd.LiveAxes, 'Voltage (V)')
            cd.LiveAxes.XTickLabelRotation = 0;
            cd.LiveAxes.YTickLabelRotation = 0;
            cd.LiveAxes.ZTickLabelRotation = 0;
            cd.LiveAxes.Position = [6 8 602 423];

            % Create AutoscaleYSwitchLabel
            cd.AutoscaleYSwitchLabel = uilabel(cd.LiveViewPanel);
            cd.AutoscaleYSwitchLabel.HorizontalAlignment = 'center';
            cd.AutoscaleYSwitchLabel.Position = [9 440 70 22];
            cd.AutoscaleYSwitchLabel.Text = 'Autoscale Y';

            % Create AutoscaleYSwitch
            cd.AutoscaleYSwitch = uiswitch(cd.LiveViewPanel, 'slider');
            cd.AutoscaleYSwitch.ValueChangedFcn = createCallbackFcn(cd, @AutoscaleYSwitchValueChanged, true);
            cd.AutoscaleYSwitch.Position = [102 441 45 20];
            cd.AutoscaleYSwitch.Value = 'On';

            % Create YminEditFieldLabel
            cd.YminEditFieldLabel = uilabel(cd.LiveViewPanel);
            cd.YminEditFieldLabel.HorizontalAlignment = 'right';
            cd.YminEditFieldLabel.Position = [186 440 33 22];
            cd.YminEditFieldLabel.Text = 'Ymin';

            % Create YminEditField
            cd.YminEditField = uieditfield(cd.LiveViewPanel, 'numeric');
            cd.YminEditField.ValueChangedFcn = createCallbackFcn(cd, @YmaxminValueChanged, true);
            cd.YminEditField.Position = [226 440 52 22];
            cd.YminEditField.Value = -1;

            % Create YmaxEditFieldLabel
            cd.YmaxEditFieldLabel = uilabel(cd.LiveViewPanel);
            cd.YmaxEditFieldLabel.HorizontalAlignment = 'right';
            cd.YmaxEditFieldLabel.Position = [291 440 36 22];
            cd.YmaxEditFieldLabel.Text = 'Ymax';

            % Create YmaxEditField
            cd.YmaxEditField = uieditfield(cd.LiveViewPanel, 'numeric');
            cd.YmaxEditField.ValueChangedFcn = createCallbackFcn(cd, @YmaxminValueChanged, true);
            cd.YmaxEditField.Position = [334 440 52 22];
            cd.YmaxEditField.Value = 1;

            % Show the figure after all components are created
            cd.LiveDataAcquisitionUIFigure.Visible = 'on';
        end

        function cd = startupFcn(cd)
            
            % This function executes when the app starts, before user interacts with UI
            % Get connected devices that have the supported subsystem and measurement types
            % Detect all connected devices
            devices = daqlist;
            cd.DevicesInfo = devices;

            % Set the app controls in device selection state
%             setViewState(app, 'deviceselection');
            drawnow

            % Populate the device drop down list with cell array of composite device names (ID + model)
            % First element is "Select a device"
            ids = devices.DeviceID;
            models = devices.Model;
            deviceDescriptions = cellstr(ids + " [" + models + "]");
            cd.DeviceDropDown.Items = ['Select a device'; deviceDescriptions];
            
            % Assign dropdown ItemsData to correspond to device index + 1
            % (these are like references to the items
            % (first item is not a device)
            cd.DeviceDropDown.ItemsData = 1:numel(devices)+1;
            
            % Create a line plot and store its handle in LivePlot app property
            % This is used for updating the live plot from scansAvailable_Callback function
            cd.LivePlotLine = plot(cd.LiveAxes, NaN, NaN);
            
            % Turn off axes toolbar and data tips for live plot axes
            cd.LiveAxes.Toolbar.Visible = 'off';
            disableDefaultInteractivity(cd.LiveAxes);

            % Initialize the AutoscaleYSwitch, YminSpinner, and YmaxSpinner components in the correct
            % state (AutoscaleYSwitch enabled, YminSpinner and YmaxSpinner disabled).
            updateAutoscaleYSwitchComponents(cd)
        end
    end

    methods (Access = public)
        %Constructor
        function cd = ChannelDashboard
          
            % Create all associated components
            cd = createComponents(cd);

            % Execute the startup function
            cd = startupFcn(cd);

            if nargout == 0
                clear app
            end
        end


    end
    
end

