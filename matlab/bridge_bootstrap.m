% Start a named local MATLAB Engine session. No permanent path changes.
bridgeFolder = fileparts(mfilename('fullpath'));
addpath(bridgeFolder);
if ~matlab.engine.isEngineShared
    matlab.engine.shareEngine('MATLAB_AI_BRIDGE');
end
fprintf('\nMATLAB AI bridge ready: %s | %s\n', ...
    matlab.engine.engineName, version);
clear bridgeFolder
