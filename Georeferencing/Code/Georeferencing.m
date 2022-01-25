%% Georeferencing - Trajectory matching
% Author: SIMP Team
clearvars
close all
format longG
clc
fprintf('Georeferencing - Trajectory matching\n')

addpath(genpath('..\'))

%% Load Data and define parameters
% Define lever arm [m]
leverArm = [-0.011 0.134 0.397]';       % from CAD model
step = 0.1;

[GNSSFileName,GNSSPathName,~] = uigetfile('*.txt;*.mat', 'Select the input GNSS Trajectory File', '..\Data');
[ScanTFileName,ScanTPathName,~] = uigetfile('*.txt;*.mat', 'Select the input Scan Trajectory File', '..\Data');
[ScanPCFileName,ScanPCPathName,~] = uigetfile('*.laz;*.las', 'Select the input Scan Pointcloud File', '..\Data');

% Load GNSS trajectory (format: [time [s], X [m], Y [m], Z [m]])
load([GNSSPathName GNSSFileName],'POS','POS_label','GPS_1','GPS_label');
% load('Data\testGNSS_RTK.mat','POS','POS_label','GPS2','GPS2_label');

% Select GPS2 (GNSS only) or KF-Solution (GNSS + IMU) and transform to flat
% earth frame for easier usage and orientation
% GNSS = lla2ecef(POS(:,3:5));            % transform to ECEF [m]
% GNSS = [POS(:,2)*1e-6 GNSS];            % add time in [s]
% GNSS = lla2ecef(GPS2(:,8:10));          % transform to ECEF [m]
% GNSS = [GPS2(:,2)*1e-6 GNSS];           % add time in [s]
flatRef = [mean(GPS_1(:,9:10)) 0];                  % reference point for flat earth [°, °, m]
GNSS = lla2flat(GPS_1(:,9:11),flatRef(1:2),0,0);    % flat earth coordinates [m]
GNSS = [GNSS(:,2) GNSS(:,1) GNSS(:,3)];             % Switch order to X, Y, Z

% Load Scanner trajectory (format: [time [s], X [m], Y [m], Z [m] ...])
ScanRaw = load([ScanTPathName ScanTFileName]);
% ScanRaw = load('Data\testSCAN_RTK.txt');

% Add lever arm to scan trajectory with orientation from scanner
Scan = simulateGNSS(ScanRaw, leverArm);
% Scan = ScanRaw;
ScanBackup = Scan;                        % save original Scan trajectory

% Reduce scan trajectory times 
Scan(:,1) = Scan(:,1)-Scan(1,1);

% Load Scan Point Cloud Data
ScanPC = lasdata([ScanPCPathName, ScanPCFileName], 'loadall');

%% Calculate Time Offset
% Get GPS time 
epoch = datetime(1980,1,6,'TimeZone','UTCLeapSeconds');
dtUTC = datenum(epoch + days(GPS_1(:,6)*7) + seconds(GPS_1(:,5)*1e-3) + hours(1));
% datetime(dtUTC,'ConvertFrom','datenum','Format', 'yyyy-MM-dd HH:mm:ss.SSS')
GNSS = [dtUTC*24*3600 GNSS];    % add time in [seconds]
% GNSS = [GPS2(:,2)*1e-6 GNSS]; 

% Delete GNSS measurements bevore moving via time matching
[timeOffset,~] = findTimeDelay(Scan, [GNSS(:,2:4) GNSS(:,1)], 0.01);
close all   
[~,idx] = min(abs(GNSS(:,1)-GNSS(1,1)-timeOffset)); % find index of time delay
GNSS = GNSS(idx:end,:);                             % now same trajectory start as Scan

% Save GNSS trajectory as variable
% save('GNSS_Trajectory_SchlossRun.mat','GNSS');

% Get mean time step size
ScanTSS = mean(diff(Scan(:,1)));
GNSSTSS = mean(diff(GNSS(:,1)));

% Match times
timeOffset = GNSS(1,1)-Scan(1,1);
Scan(:,1) = Scan(:,1)+timeOffset;

% % Reduce coordinates for numeric stability (relevant for ECEF)
% offset = mean(GNSS(:,2:4));
% GNSS(:,2:4) = GNSS(:,2:4)-offset;
% % Scan(:,2:4) = Scan(:,2:4)-offset;

%% Coarse trajectory match
[Scan,rotScale,translation] = coarseMatch(GNSS, Scan, timeOffset);

% Plot trajectories
figure
plot3(GNSS(:,2),GNSS(:,3),GNSS(:,4),'b')
hold on
view([60 55])
grid on
plot3(Scan(:,2),Scan(:,3),Scan(:,4),'g')
legend('GNSS','SCAN','Location','NorthWest')
title('Coarse Trajectory Match Results')
view([90 90])
% print('-dpng','-r200',"CoarseTrafo.png")

%% Accurate trajectory match
[Scan,rotScale,translation] = accurateMatch(GNSS, Scan, timeOffset, rotScale, translation, 7, 200, 1, 0);

% % Add initial offset (relevant for ECEF)
% translation = translation + offset';
% GNSS(:,2:4) = GNSS(:,2:4) + offset;

%% Test transformation on original trajectory
% Transform trajectory and plot anew
figure
plot3(GNSS(:,2),GNSS(:,3),GNSS(:,4),'b')
hold on 
view([60 55])
grid on
for i = 1:length(ScanBackup)
   ScanBackup(i,2:4) = rotScale * ScanBackup(i,2:4)' + translation;
end
plot3(ScanBackup(:,2),ScanBackup(:,3),ScanBackup(:,4),'g')
% axis equal
legend('GNSS','SCAN','Location','NorthWest')
title('Combined Transformation (Coarse + Accurate)')
view([90 90])
% print('-dpng','-r200',"AccurateTrafo_Good.png")

% Save Scan trajectory as variable
% save('Scan_Trajectory_SchlossRun.mat','Scan','rotScale');

%% Estimate point matching accuracy
% Find corresponding match points in a loop
bound = 200;
for i = 1:length(GNSS)
    % Get approximate Scan index
    idx = round((GNSS(i,1)-timeOffset)/ScanTSS)+1;
    if idx > length(Scan)
        idx = length(Scan);
    end

    % Estimate lower and upper bound for threshold
    if idx-round(bound/2) < 1
        idxLB = 1;
    else
        idxLB = idx-round(bound/2);
    end

    if idx+round(bound/2) > length(Scan)
        idxUB = length(Scan);
    else
        idxUB = idx+round(bound/2);
    end

    % Find closest Scan point in threshold and save index and distance
    % match order: [GNSSIDX, ScanIDX, distance, dist in XY, dist in x,y,z]
    [~, matchIDX] = min(vecnorm(Scan(idxLB:idxUB,2:4)-GNSS(i,2:4),2,2));
    dist = norm(Scan(idxLB + matchIDX - 1,2:4)-GNSS(i,2:4));
    distxy = norm(Scan(idxLB + matchIDX - 1,2:3)-GNSS(i,2:3));
    distx = norm(Scan(idxLB + matchIDX - 1,2)-GNSS(i,2));
    disty = norm(Scan(idxLB + matchIDX - 1,3)-GNSS(i,3));
    distz = norm(Scan(idxLB + matchIDX - 1,4)-GNSS(i,4));
    match(i,:) = [i, idxLB + matchIDX - 1, dist, distxy, distx, disty, distz];
end

% Calculate standard deviations and mean point distances
stdev = norm(match(:,3))/sqrt(length(match));         % standard deviation 
stdevxy = norm(match(:,4))/sqrt(length(match));       % standard deviation x,y
meandiff = sum(match(:,3))/length(match);             % mean point match distance
meandiffxy = sum(match(:,4))/length(match);           % mean point match distance x,y
[stdx, stdy, stdz] = deal(norm(match(:,5))/sqrt(length(match)), norm(match(:,6))/sqrt(length(match)), norm(match(:,7))/sqrt(length(match)));
[meanx, meany, meanz] = deal(sum(match(:,5))/length(match), sum(match(:,6))/length(match), sum(match(:,7))/length(match));

% Output results
fprintf('\n3D Accuracy (X, Y, Z):\n')
fprintf('Mean point match distance: %.3f m\n',meandiff)
fprintf('Standard deviation: %.3f m\n',stdev)
fprintf('\n2D Accuracy (X, Y):\n')
fprintf('Mean point match distance: %.3f m\n',meandiffxy)
fprintf('Standard deviation: %.3f m\n',stdevxy)
fprintf('\nAccuracy in X, Y, Z:\n')
fprintf('Mean point match distance (X,Y,Z): [%.3f %.3f %.3f] m\n',meanx,meany,meanz)
fprintf('Standard deviation (X,Y,Z): [%.3f %.3f %.3f] m\n',stdx,stdy,stdz)

% Plot point match distance in all axes
figure
hold on
grid on
plot(1:length(match), match(:,5));
plot(1:length(match), match(:,6));
plot(1:length(match), match(:,7));
legend('in X','in Y','in Z')
title('Point match distance')
xlabel('Time')
ylabel('Distance [m]')
% print('-dpng','-r200',"Error_withoutLever.png")

%% Transform Point Cloud
PC_transf = [ScanPC.x, ScanPC.y, ScanPC.z] * rotScale' + translation';

% Save for ColorCoding in Flat Earth (remove when including ColorCoding)
ScanPC.header.max_x = max(PC_transf(:,1));
ScanPC.header.min_x = min(PC_transf(:,1));
ScanPC.header.max_y = max(PC_transf(:,2));
ScanPC.header.min_y = min(PC_transf(:,2));
ScanPC.header.max_z = max(-PC_transf(:,3));
ScanPC.header.min_z = min(-PC_transf(:,3));

ScanPC.header.x_offset = mean(PC_transf(:,1));
ScanPC.header.y_offset = mean(PC_transf(:,2));
ScanPC.header.z_offset = mean(-PC_transf(:,3));

ScanPC.y = PC_transf(:,1);%-ScanPC.header.x_offset;
ScanPC.x = PC_transf(:,2);%-ScanPC.header.y_offset;
ScanPC.z = -PC_transf(:,3);%-ScanPC.header.z_offset;

% write_las(ScanPC, [ScanPCPathName, 'GeoreferencedPointcloud3Schloss.las']);

% Save finally in ECEF
PC_transf = lla2ecef(flat2lla(PC_transf, flatRef(1:2),0, 0));

ScanPC.header.max_x = max(PC_transf(:,1));
ScanPC.header.min_x = min(PC_transf(:,1));
ScanPC.header.max_y = max(PC_transf(:,2));
ScanPC.header.min_y = min(PC_transf(:,2));
ScanPC.header.max_z = max(PC_transf(:,3));
ScanPC.header.min_z = min(PC_transf(:,3));

ScanPC.header.x_offset = mean(PC_transf(:,1));
ScanPC.header.y_offset = mean(PC_transf(:,2));
ScanPC.header.z_offset = mean(PC_transf(:,3));

ScanPC.x = PC_transf(:,1);%-ScanPC.header.x_offset;
ScanPC.y = PC_transf(:,2);%-ScanPC.header.y_offset;
ScanPC.z = PC_transf(:,3);%-ScanPC.header.z_offset;

% write_las(ScanPC, [ScanPCPathName, 'GeoreferencedPointcloud.las']);

%% TODO: 
%       - Scan mehr Punkte oder GNSS meh Punkte unabhängig
%       - Further improve weighting based on GNSS reliability