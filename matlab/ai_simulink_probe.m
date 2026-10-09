function result=ai_simulink_probe()
% Installation metadata only: do not enumerate or inspect user models.
products=ver;
result=jsonencode(struct('ok',true,'simulink_installed',any(strcmp({products.Name},'Simulink')), ...
    'stateflow_installed',any(strcmp({products.Name},'Stateflow')),'release',version('-release')));
end
