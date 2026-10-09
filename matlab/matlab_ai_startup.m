function matlab_ai_startup()
% Open the assistant after the MATLAB desktop has completed startup.
if ~usejava('desktop'), return; end
if ~isempty(timerfindall('Tag','MatlabAIStartup')), return; end
startupTimer = timer('ExecutionMode','singleShot','StartDelay',2, ...
    'Tag','MatlabAIStartup','TimerFcn',@openAssistant);
start(startupTimer);
end

function openAssistant(startupTimer,~)
cleanup = onCleanup(@() delete(startupTimer));
try
    if ~matlab.engine.isEngineShared
        try
            matlab.engine.shareEngine('MATLAB_AI_BRIDGE');
        catch
            % Another desktop may already own the bridge name. The UI works
            % directly in MATLAB and does not depend on engine sharing.
        end
    end
    matlab_ai;
catch exception
    warning('MatlabAI:Startup','AI assistant startup failed: %s',exception.message);
end
end
