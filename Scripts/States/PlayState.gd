extends Node2D

signal event_activated(eventName, eventArgs)

signal note_hit(rating, must_hit, note_type, timing)
signal note_missed()
signal note_created(note)

# constants
# hit timings and windows
# {rating name: [min ms, score]}
const HIT_TIMINGS = {"shit": [140, 50, 0.25], "bad": [120, 100, 0.50], "good": [90, 200, 0.75], "sick": [60, 350, 1]}
#const HIT_TIMINGS = {"shit": [140, 50, 0.25], "bad": [120, 100, 0.50], "good": [100, 200, 0.75], "sick": [80, 350, 1]}

# preloading nodes
const PAUSE_SCREEN = preload("res://Scenes/States/PlayState/PauseMenu.tscn")
const GAME_OVER = preload("res://Scenes/States/PlayState/GameOverState.tscn")

const MISS_SOUNDS = [preload("res://Assets/Sounds/missnote1.ogg"),
					preload("res://Assets/Sounds/missnote2.ogg"),
					preload("res://Assets/Sounds/missnote3.ogg")]
					
var RATING_SCENE = preload("res://Scenes/States/PlayState/Rating.tscn")

# notes
const NOTES = {
	"": preload("res://Scenes/States/PlayState/Notes/Note.tscn"),
	"mine": preload("res://Scenes/States/PlayState/Notes/NoteMine.tscn"),
	"warn": preload("res://Scenes/States/PlayState/Notes/NoteWarn.tscn")
}
const NOTE_SPLASH = preload("res://Scenes/States/PlayState/NoteSplash.tscn")

enum Note {Left, Down, Up, Right}

var rng = RandomNumberGenerator.new() # rng stuff for miss sounds in particular

# exports
export (NodePath) var PlayerStrumPath
export (NodePath) var EnemyStrumPath

export (String) var PlayerCharacter
export (String) var EnemyCharacter
export (String) var GFCharacter

export (String) var song = "no-villains"
export (String) var difficulty = "hard"
export (float) var speed = 1

export (String) var noteSkin = "Default"

# player stats
var health = 50
var score = 0
var misses = 0
var realMisses = 0
var combo = 0

var totalHitNotes = 0
var hitNotes = 0
var isGFC = true

# story vars
var storyMode = false
var storySongs = []

# arrays holding the waiting for notes and sections
var notes
var sections
var events

var must_hit_section = false # if the section should be hit or not

# get the node paths for the strums
var PlayerStrum
var EnemyStrum

var MusicStream # might replace this because its only used like once

# other
var finished = false
var chartingMode = true

onready var healthShakePos = $HUD/HudElements/HealthBar.rect_position
var healthShakeTimer = 0
var healthShakeIntensity = 1

var hudBopCounter = 0
var maxHudBop = 4
var maxHudScale = 1.02

var freeCamera = false
var cameraTimer = -1

# old vars
var oldHealth = health

# skinning?

func _enter_tree():
	Main.load_note_sprites(noteSkin)

func _ready():
	# get the strums nodes
	PlayerStrum = get_node(PlayerStrumPath)
	EnemyStrum = get_node(EnemyStrumPath)
	
	MusicStream = get_tree().current_scene.get_node("Music/MusicStream") # get the music streams nodes
	
	setup_characters() # setup the characters positions and icons
	setup_strums() # setup the positions and stuff for strums
	
	load_song_scripts()
	
	rng.randomize() # randomize the rng variable's seed
	
	# tell the conductor to play the currently selected song
	# i might just remove the playstate entirely for this process, and only use the conductor
	if (!chartingMode):
		Conductor.songData = null
	
	Conductor.play_chart(song, difficulty, speed)
	
	var _c_beat = Conductor.connect("beat_hit", self, "hud_bop") # connect the beat hit signal to the icon bop
	connect("event_activated", self, "on_event")
	
func _process(_delta):
	player_input() # handle the players input
	
	spawn_notes() # create the needed notes
	get_section() # get the current section
	get_event()
	
	# pause the game
	if (Input.is_action_just_pressed("confirm")):
		get_tree().paused = true
		var pauseMenu = PAUSE_SCREEN.instance()
		get_tree().current_scene.add_child(pauseMenu)
	
	# process health bar stuff, like positions
	health_bar_process(_delta)
	
	if (Conductor.notesFinished):
		song_finished_check()
		
	if (cameraTimer > 0):
		cameraTimer -= _delta
	elif (cameraTimer != -1):
		cameraTimer = -1
		freeCamera = false

	$HUD/HudElements.scale = lerp($HUD/HudElements.scale, Vector2(1,1), _delta * 5)

func _input(event):
	# debug shit
	if (event is InputEventKey):
		if (event.pressed):
			match (event.scancode):
				KEY_7:
					Main.change_chart_state()

func player_input():
	if (PlayerStrum == null || Settings.botPlay):
		return
	
	# ah
	button_logic(PlayerStrum, Note.Left)
	button_logic(PlayerStrum, Note.Down)
	button_logic(PlayerStrum, Note.Up)
	button_logic(PlayerStrum, Note.Right)

func button_logic(line, note, buttonOverride=null, actionOverride=null):
	
	# get the buttons name and action
	var buttonName = "Left"
	var action = "left"
	match (note):
		Note.Down:
			buttonName = "Down"
			action = "down"
		Note.Up:
			buttonName = "Up"
			action = "up"
		Note.Right:
			buttonName = "Right"
			action = "right"
	
	if (buttonOverride != null):
		if (buttonOverride is String):
			buttonName = buttonOverride
	
	if (actionOverride != null):
		if (actionOverride is String):
			action = actionOverride
	
	# get the nodesr
	var button = line.get_node("Buttons/" + buttonName)
	var animation = button.get_node("AnimationPlayer")
	
	if (Input.is_action_pressed(action)):
		if (PlayerCharacter != null && PlayerCharacter.get_node("AnimationPlayer").assigned_animation != PlayerCharacter.get_idle_anim()):
			if (PlayerCharacter.idleTimer <= 0.05):
				PlayerCharacter.idleTimer = 0.05
	
	# check if the action is pressed
	if (Input.is_action_just_pressed(action)):
		# check each note to make for the closest one
		# this kinda sucks
		var activeNotes = line.get_node("Notes").get_children()
		
		var curNote = null
		var distance
		# check if the note type is correct, and the distance is less then the worst spot
		for noteChild in activeNotes:
			if (noteChild.note_type == note):
				distance = (Conductor.songPositionMulti - noteChild.strum_time) * 1000
				var worstRating = HIT_TIMINGS.keys()[0]
				if (abs(distance) <= HIT_TIMINGS[worstRating][0]):
					curNote = noteChild
					break
		
		# if there is a note, play the hitsound and hit the note
		if (curNote != null):
			if (Settings.hitSounds):
				$Audio/HitsoundStream.play()
			
			curNote.note_hit(distance)
			
			# shubs duped note check thing
			# (thanks shubs you are awesome)
			for dupedNote in activeNotes:
				if (dupedNote == curNote):
					continue
				
				if (dupedNote.note_type == curNote.note_type):
					if (dupedNote.strum_time <= curNote.strum_time + 0.01):
						dupedNote.queue_free()
		
		# miss if pressed when there is no note
		# also play the pressed animation
		if (animation.assigned_animation == "idle"):
			if (!Settings.ghostTapping):
				on_miss(true, note)
			animation.play("pressed")
	
	# when the button is released, go back to the idle animation
	if (Input.is_action_just_released(action)):
		animation.play("idle")

func spawn_notes():
	if (notes == null || notes.empty()):
		return
	
	var note = notes[0]
	
	if Conductor.songPositionMulti >= note[0] - Conductor.SCROLL_TIME / Conductor.scroll_speed:
		if (notes.has(note)):
			notes.erase(note)
		
		var strum_time = note[0]
		var direction = note[1]
		var sustain_length = note[2]
		var arg3 = note[3]
		
		spawn_note(direction, strum_time, sustain_length, arg3)
		
func get_section():
	if (sections == null || sections.empty()):
		return
	
	var section = sections[0]
	
	if MusicStream.get_playback_position() >= section[0]:
		if (sections.has(section)):
			sections.erase(section)
		
		if (Conductor.startingPosition != 0):
			if (section[0] < Conductor.startingPosition):
				return
			
		var character
		
		must_hit_section = section[1]
		if (must_hit_section):
			if (PlayerCharacter != null):
				character = PlayerCharacter
		else:
			if (EnemyCharacter != null):
				character = EnemyCharacter
				
		EnemyCharacter.useAlt = section[2]
		
		if (character != null && !freeCamera):
			if (character.flipX):
				$Camera.position = character.position + character.camOffset
			else:
				$Camera.position = character.position + Vector2(-character.camOffset.x, character.camOffset.y)

func get_event():
	if (events == null || events.empty()):
		return
		
	var event = events[0]
	
	if MusicStream.get_playback_position() >= event[0]:
		if (events.has(event)):
			events.erase(event)
		
		if (Conductor.startingPosition != 0):
			if (event[0] < Conductor.startingPosition):
				return
		
		emit_signal("event_activated", event[1], event[3])
		print(event[1], event[3])

func spawn_note(dir, strum_time, sustain_length, arg3=null):
	var oldDir = dir
	
	if (dir > 7):
		dir = 7
	if (dir < 0):
		dir = 0
	
	var strumLine = PlayerStrum
	
	if (dir > 3):
		strumLine = EnemyStrum
		dir -= 4
	
	if (strumLine != null):
		var curNote = ""
		
		if (arg3 != null):
			var idealNote = str(arg3)
			
			if (Conductor.chartType == "PSYCH"):
				match arg3:
					"Hurt Note":
						idealNote = "mine"
					"halfBlammed Note":
						idealNote = "warn"
					_:
						return
			
			if (idealNote in NOTES.keys()):
				print(idealNote)
				curNote = idealNote
		
		var note = NOTES[curNote].instance()
		
		var spawn_lane
		match dir:
			Note.Left:
				spawn_lane = strumLine.get_node("Buttons/Left")
			Note.Down:
				spawn_lane = strumLine.get_node("Buttons/Down")
			Note.Up:
				spawn_lane = strumLine.get_node("Buttons/Up")
			Note.Right:
				spawn_lane = strumLine.get_node("Buttons/Right")
		
		note.position.x = spawn_lane.position.x
		note.position.y = 1280
		
		note.strum_lane = spawn_lane
		note.strum_time = strum_time
		note.sustain_length = sustain_length
		note.note_type = dir
		note.dir = oldDir
		
		if (strumLine == PlayerStrum):
			note.must_hit = true
		
		emit_signal("note_created", note)
		note.strum_lane.get_parent().get_parent().get_node("Notes").add_child(note)

func on_hit(note, timing):
	var must_hit = note.must_hit
	var note_type = note.note_type

	var character = EnemyCharacter
	if (must_hit):
		character = PlayerCharacter
	
	if (character != null):
		var animName = player_sprite(note_type, "")
		character.play(animName)
		character.idleTimer = 0.2
		
		if (Settings.cameraMovement && !freeCamera):
			if (must_hit && must_hit_section || !must_hit && !must_hit_section):
				var offsetVector = character.camOffset
				var intensity = 10
				
				match (note_type):
					Note.Left:
						if (character.flipX):
							offsetVector.x += -intensity
						else:
							offsetVector.x += intensity
					Note.Right:
						if (character.flipX):
							offsetVector.x += intensity
						else:
							offsetVector.x += -intensity
					Note.Down:
						offsetVector.y += intensity
					Note.Up:
						offsetVector.y += -intensity

				if (character.flipX):
					$Camera.position = character.position + Vector2(offsetVector.x, offsetVector.y)
				else:
					$Camera.position = character.position + Vector2(-offsetVector.x, offsetVector.y)
	
	var rating = get_rating(timing)
	if (must_hit):
		var timingData = HIT_TIMINGS[rating]
		score += timingData[1]
		health += 1.5
		
		if (combo < 0):
			combo = 0
		combo += 1
		
		hitNotes += timingData[2]
		totalHitNotes += 1
		$HUD/HudElements/TextBar/AnimationPlayer.play("textBop")
	
	if (must_hit) and $HUD/HudElements/TextBar/AnimationPlayer.is_playing():
		$HUD/HudElements/TextBar/AnimationPlayer.stop()
		
		$HUD/HudElements/TextBar/AnimationPlayer.play("textBop")
		
		
		if (rating != "sick" && rating != "good"):
			isGFC = false
		
		if (rating == "sick"):
			var splash = NOTE_SPLASH.instance()
			var num = rng.randi_range(0, 1)
			var anim = "Left"
			
			var color
			
			match note_type:
				Note.Left:
					anim = "Left"
				Note.Down:
					anim = "Down"
				Note.Up:
					anim = "Up"
				Note.Right:
					anim = "Right"
			
			var strumButton = note.strum_lane
			splash.position = PlayerStrum.position + strumButton.position
			
			color = strumButton.noteColor
			
			if (Settings.customNoteColors || Settings.noteQuants):
				anim = "Desat"
				splash.self_modulate = color
				splash.get_node("Overlay").visible = true
				splash.get_node("Overlay").play(str(num))
			
			splash.play(anim.to_lower() + str(num))
			
			if (Settings.noteSplashes):
				$HUD/HudElements.add_child(splash)
		
		create_rating(HIT_TIMINGS.keys().find(rating), timing)
		
	emit_signal("note_hit", rating, must_hit, note_type, timing)
		
	Conductor.muteVocals = false

func on_miss(must_hit, note_type, passed = false):
	var character = EnemyCharacter
	if (must_hit):
		character = PlayerCharacter
	
	if (character != null):
		var animName = player_sprite(note_type, "Miss")
		character.play(animName)
	
	var random = rng.randi_range(0, MISS_SOUNDS.size()-1)
	$Audio/MissStream.stream = MISS_SOUNDS[random]
	$Audio/MissStream.play()
	
	health -= 5.0
	if (!passed):
		score -= 10
		misses += 1
	else:
		realMisses += 1
		Conductor.muteVocals = true
		emit_signal("note_missed")
	
	if (combo > 0):
		combo = 0
	combo -= 1
	
	if (Settings.hudRatingsMiss):
		create_rating(-1, 0)
	
	shake_health()

func get_rating(timing):
	# get the last rating in the array and set it to the default (the last rating is the best)
	var ratings = HIT_TIMINGS.keys()
	var chosenRating = ratings[ratings.size()-1]
	
	# loop through each rating and check if the number is less then the next rating
	# if it is set the chosen rating to the worse value
	for rating in ratings:
		var maxTiming = 0 # set it to the best timing you can get
		# if there is a next rating, set max timing to that instead
		if (ratings.find(rating) + 1 < ratings.size()):
			maxTiming = HIT_TIMINGS[ratings[ratings.find(rating) + 1]][0]
		
		# check if the timing is less then the next rating
		if (abs(timing) < maxTiming):
			# if it isnt continue to the next
			continue
		else:
			# if it is, choose that rating and break out of the loop
			chosenRating = rating
			break
	
	return chosenRating

func player_sprite(note_type, prefix):
	var animName = "idle"
	
	match (note_type):
		Note.Left:
			animName = "singLEFT"
		Note.Down:
			animName = "singDOWN"
		Note.Up:
			animName = "singUP"
		Note.Right:
			animName = "singRIGHT"
				
	return animName + prefix

func health_bar_process(delta):
	var bar = $HUD/HudElements/HealthBar
	var icons = $HUD/HudElements/HealthBar/Icons
	
	health = clamp(health, 0, 100)
	
	if (Conductor.countingDown && misses == 0):
		oldHealth = lerp(oldHealth, health, 3 * delta)
		bar.value = oldHealth
	else:
		bar.value = health
		
	icons.position.x = -(bar.value * (bar.rect_size.x / 100)) + bar.rect_size.x
	
	var barOffset = 20
	if (bar.value > 100 - barOffset):
		$HUD/HudElements/HealthBar/Icons/Enemy.frame = 1
		
		if ($HUD/HudElements/HealthBar/Icons/Player.hframes > 2):
			$HUD/HudElements/HealthBar/Icons/Player.frame = 2
		else:
			$HUD/HudElements/HealthBar/Icons/Player.frame = 0
	elif (bar.value < barOffset):
		$HUD/HudElements/HealthBar/Icons/Player.frame = 1
		
		if ($HUD/HudElements/HealthBar/Icons/Player.hframes > 2):
			$HUD/HudElements/HealthBar/Icons/Enemy.frame = 2
		else:
			$HUD/HudElements/HealthBar/Icons/Enemy.frame = 0
	else:
		$HUD/HudElements/HealthBar/Icons/Enemy.frame = 0
		$HUD/HudElements/HealthBar/Icons/Player.frame = 0
	
	var accuracyString = "N/A"
	var letterRating = ""
	var accuracy = 0
	if (hitNotes > 0):
		var totalNotes = float(totalHitNotes + realMisses)
		accuracy = round((float(hitNotes) / totalNotes) * 10000) / 100
		
		accuracyString = str(accuracy) + "%"
		letterRating = " [" + get_letter_rating(accuracy) + "]"
	
	$HUD/HudElements/TextBar.text = "Score: " + str(score) + " | Misses: " + str(misses + realMisses) + " | " + accuracyString + letterRating
	
	if (Settings.hudProgressBar):
		$HUD/HudElements/TopBar/Progress.value = MusicStream.get_playback_position()
		$HUD/HudElements/TopBar/Progress.max_value = MusicStream.stream.get_length()
		$HUD/HudElements/TopBar/TopBarLabel.text = song.capitalize() + " | " + difficulty.to_upper() + " | " + Main.convert_to_time_string(MusicStream.stream.get_length() - MusicStream.get_playback_position())
	
	$HUD/HudElements/TopBar.visible = Settings.hudProgressBar
	
	$HUD/HudElements/BotplayLabel.visible = Settings.botPlay
	
	$HUD/HudElements/Background.color.a = Settings.backgroundOpacity
	
	if (healthShakeTimer > 0):
		$HUD/HudElements/HealthBar.rect_position = healthShakePos + Vector2(rng.randi_range(-healthShakeIntensity, healthShakeIntensity), rng.randi_range(-healthShakeIntensity, healthShakeIntensity))
		healthShakeTimer -= delta
	else:
		$HUD/HudElements/HealthBar.rect_position = healthShakePos
	
	if (Input.is_action_just_pressed("reset")):
		health = 0
	
	if (health <= 0):
		Conductor.MusicStream.stop()
		Conductor.VocalStream.stop()
		
		var gameoverScene = GAME_OVER.instance()
		gameoverScene.get_node("DeathSprite").position = PlayerCharacter.position + PlayerCharacter.get_node("Sprite").position
		
		gameoverScene.get_node("Camera2D").position = $Camera.position
		gameoverScene.get_node("Camera2D").zoom = $Camera.zoom
		
		if (storyMode):
			storySongs.push_front("lose")
		else:
			storySongs = null
		
		gameoverScene.song = song
		gameoverScene.difficulty = difficulty
		gameoverScene.speed = speed
		gameoverScene.storySongs = storySongs
		gameoverScene.chartingMode = chartingMode
		
		Main.change_scene(gameoverScene, false)
		
func get_letter_rating(accuracy):
	var letterRatings = {"A+": 95, "A": 85, "B+": 77.5, "B": 72.5, "C+": 67.5, "C": 62.5, "D+": 57.5, "D": 52.5, "E": 45, "F": 20}
	
	var chosenRating = letterRatings.keys()[letterRatings.keys().size()-1]
	var prefix = ""
	
	for rating in letterRatings.keys():
		if (accuracy >= letterRatings[rating]):
			chosenRating = rating
			break
	
	if (realMisses == 0):
		if (totalHitNotes == hitNotes):
			prefix = " | SFC"
		elif (isGFC):
			prefix = " | GFC"
		else:
			prefix = " | FC"
	
	return chosenRating + prefix

func hud_bop():
	$HUD/HudElements/HealthBar/Icons/AnimationPlayer.play("Bop")
	
	hudBopCounter += 1
	if (hudBopCounter >= maxHudBop):
		$HUD/HudElements.scale = Vector2(maxHudScale, maxHudScale)
		hudBopCounter = 0


func setup_characters():
	if (GFCharacter != null):
		GFCharacter = Main.create_character(GFCharacter)
		$Characters.add_child(GFCharacter)
		
		GFCharacter.position = $Positions/Girlfriend.position
		$Camera.position = GFCharacter.position + GFCharacter.camOffset
	
	if (EnemyCharacter != null):
		EnemyCharacter = Main.create_character(EnemyCharacter)
		$Characters.add_child(EnemyCharacter)
		
		if (EnemyCharacter.girlfriendPosition):
			EnemyCharacter.position = $Positions/Girlfriend.position
		else:
			EnemyCharacter.position = $Positions/Enemy.position
			EnemyCharacter.flipX = !EnemyCharacter.flipX
		
		setup_icon($HUD/HudElements/HealthBar/Icons/Enemy, EnemyCharacter)
		$HUD/HudElements/HealthBar.tint_under = EnemyCharacter.characterColor
	
	if (PlayerCharacter != null):
		PlayerCharacter = Main.create_character(PlayerCharacter)
		$Characters.add_child(PlayerCharacter)
		
		if (PlayerCharacter.girlfriendPosition):
			PlayerCharacter.position = $Positions/Girlfriend.position
		else:
			PlayerCharacter.position = $Positions/Player.position
		
		setup_icon($HUD/HudElements/HealthBar/Icons/Player, PlayerCharacter)
		$HUD/HudElements/HealthBar.tint_progress = PlayerCharacter.characterColor
		
	if (PlayerCharacter.girlfriendPosition || EnemyCharacter.girlfriendPosition):
		GFCharacter.queue_free()

func setup_icon(node, character):
	var frames = character.iconSheet.get_width() / 150
	
	node.texture = character.iconSheet
	node.hframes = frames
	
func setup_strums():
	if (Settings.downScroll):
		PlayerStrum.position.y = 386
		for button in PlayerStrum.get_node("Buttons").get_children():
			button.moveScale = -1
		
		EnemyStrum.position.y = 386
		for button in EnemyStrum.get_node("Buttons").get_children():
			button.moveScale = -1
		
		$HUD/HudElements/HealthBar.rect_position.y = -404
		$HUD/HudElements/TextBar.rect_position.y = -454
		
	if (Settings.middleScroll):
		PlayerStrum.position.x = -241
		
		if (Settings.middleScrollPreview):
			if (!Settings.downScroll):
				EnemyStrum.position = Vector2(-751, -204)
			else:
				EnemyStrum.position = Vector2(-751, 226)
			
			EnemyStrum.scale = EnemyStrum.scale * 0.5
		else:
			EnemyStrum.visible = false
	
	healthShakePos = $HUD/HudElements/HealthBar.rect_position

func create_rating(rating, timing):
	var ratingObj = RATING_SCENE.instance()
	ratingObj.get_node("Sprite").frame = rating+1
	ratingObj.combo = combo
	ratingObj.offset = timing
	
#	if (totalHitNotes == hitNotes):
#		ratingObj.modulate = Color.gold

	if (!Settings.hudRatings):
		ratingObj.position = $Positions/Rating.position
		$Ratings.add_child(ratingObj)
	else:
		ratingObj.position = (Settings.hudRatingsOffset / 0.7) - Vector2(896, 504)
		ratingObj.get_node("Sprite").scale = Vector2(1, 1)
		$HUD/HudElements/Ratings.add_child(ratingObj)

func restart_playstate():
	if (storyMode):
		storySongs.push_front("awesome")
	else:
		storySongs = null
	
	Main.change_playstate(song, difficulty, speed, storySongs, true, null, chartingMode)

func song_finished_check():
	if (finished):
		return
	
	if (MusicStream.get_playback_position() >= MusicStream.stream.get_length()):
		finished = true
		
		if (len(storySongs) == 0 || !storyMode):
			var difNumber = 0
			match (difficulty):
				"normal":
					difNumber = 1
				"hard":
					difNumber = 2
			
			Conductor.save_score(Conductor.songName, score, difNumber)
			
			var menuSong = load("res://Assets/Music/freakyMenu.ogg")
			if (Conductor.MusicStream.stream != menuSong):
				Conductor.play_song(menuSong, 102, 1)
			
			if (!storyMode):
				Main.change_scene("res://Scenes/States/FreePlayState.tscn")
			else:
				Main.change_scene("res://Scenes/States/StoryState.tscn")
		else:
			var dic = {
				"camPos": $Camera.position,
				"oldHealth": health
			}
			
			Main.change_playstate(storySongs[0], difficulty, 1, storySongs, false, dic)

func shake_health(time = 0.15, intensity = 8):
	healthShakeTimer = time
	healthShakeIntensity = intensity

func load_song_scripts():
	load_script(Mods.modsFolder + "script.gd")
	load_script(Mods.songsDir + "/" + song + "/script.gd")

func load_script(dir):
	var file = Mods.mod_script(dir)
	if (file is Object):
		var node = file.new()
		
		node.playState = self
		
		add_child(node)

func on_event(eventName, eventArgs):
	match eventName:
		"zoom_camera":
			var zoomTo = float(eventArgs[0])
			var zoomSpd = 0.5
			
			if (len(eventArgs) > 1):
				zoomSpd = float(eventArgs[1])
			
			var tween = Tween.new()
			
			add_child(tween)
			tween.interpolate_property($Camera, "zoom",
				$Camera.zoom, Vector2(zoomTo, zoomTo), zoomSpd,
				Tween.TRANS_QUAD, Tween.EASE_IN_OUT)
			tween.start()
		
		"play_animation":
			var character = PlayerCharacter
			match (eventArgs[0]):
				"1":
					character = EnemyCharacter
				"2":
					character = GFCharacter
			
			character.play(eventArgs[1])
		
		"change_character":
			var newCharacter = Main.create_character(eventArgs[1])
			$Characters.add_child(newCharacter)
			
			var iconRef = $HUD/HudElements/HealthBar/Icons/Player
			var pos = $Positions/Player.position
			
			var character = "PlayerCharacter"
			match (eventArgs[0]):
				"1":
					character = "EnemyCharacter"
					
					newCharacter.flipX = !newCharacter.flipX
					iconRef = $HUD/HudElements/HealthBar/Icons/Enemy
					pos = $Positions/Enemy.position
					$HUD/HudElements/HealthBar.tint_under = newCharacter.characterColor
				"2":
					character = "GFCharacter"
				_:
					$HUD/HudElements/HealthBar.tint_progress = newCharacter.characterColor
			
			if (newCharacter.girlfriendPosition):
				pos = $Positions/Girlfriend.position
			
			setup_icon(iconRef, newCharacter)
			newCharacter.position = pos
			
			var oldCharacter = get(character)
			
			oldCharacter.queue_free()
			set(character, newCharacter)
			
		"change_hud_bop":
			var _beats = 4
			var _scale = 1.02
			
			print(eventArgs)
			
			if len(eventArgs) >= 1:
				_beats = float(eventArgs[0])
			if len(eventArgs) >= 2:
				_scale = float(eventArgs[1])
				
			maxHudBop = _beats
			maxHudScale = _scale
