# DAQ_LiveDataApps

MATLAB Live Data Acquisition App that allows for data acquisition from multiple devices/channels at once, based on MathWorks' LiveDataAcquisition example code. This package allows researchers and datascientists to use DAQ devices without the need for more expensive softwares, given that the appropriate drivers and toolboxes are correctly installed. In addition, it can be run on an Apple OS, which can be a restricting factor for some softwares.

There are multiple apps packaged here:
1) MathWorks' original LiveDataAcquisition example.


2) LiveDataAppBasic: A basic modified version which allows for data acquisition of two channels using the same Device, Measurement Type, Range, Excitation Source, and Rate settings. This application is useful for simple parallel measurements and layered visualization in the same plot. Data is saved to a simple .mat file in an array, with metadata (device settings) included. App is fully completed and functional.


3) (IN DEVELOPMENT) LiveDataApp: A modified verson which allows for data acquisition of two channels using the same Device and Rate settings, but customizable other settings. This application is useful for parallel measurements in which plot data can/should be separated (i.e. measuring in different ranges, with different measurement types/devices, etc.). Data is saved to a simple .mat file in an array, with metadata (device settings) included. NOTE: App is currently in development, soon to be published.


4) (IN DEVELOPMENT) LiveDataAppAdvanced: An advanced version of the app which allows for data acquisition in multiple channels at once, fully customizable (outside of rate settings). This app opens a new window for each additional channel and uses a simple control window for parallel starts and data collection. Data is again saved to a simple .mat file with metadata included. NOTE: App is currently in development, but preliminary code can be viewed in the repository.
