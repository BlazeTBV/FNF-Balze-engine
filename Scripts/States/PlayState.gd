extends Node2D

# constants
# hit timings and windows
# {rating name: [min ms, score]}
const HIT_TIMINGS = {"shit": [180, 50], "bad": [135, 100], "good": [102, 200], "sick": [45, 350]}

# preloading nodes
const PAUSE_SCREEN = preload("res://Scenes/States/PlayState/PauseMenu.tscn")

const MISS_SOUNDS = [preload("res://Assets/Sounds/missnote1.ogg"),
					preload("res://Assets/Sounds/missnote2.ogg"),
					preload("res://Assets/Sounds/missnote3.ogg")]
					
const RATING_SCENE = preload("res://Scenes/States/PlayState/Rating.tscn")

# notes
const NOTE_NODE = preload("res://Scenes/States/PlayState/Note.tscn")
enum Note {Left, Down, Up, Right}

var rng = RandomNumberGenerator.new() # rng stuff for miss sounds in particular

# exports
export (NodePath) var PlayerStrumPath
export (NodePath) var EnemyStrumPath

export (PackedScene) var PlayerCharacter
export (PackedScene) var EnemyCharacter
export (PackedScene) var GFCharacter

export (String) var song = "no-villains"
export (String) var difficulty = "hard"
export (float) var speed = 1

# player stats
var health = 50
var score = 0
var misses = 0
var realMisses = 0
var combo = 0

var hitNotesArray = [] # all hit note timings

# arrays holding the waiting for notes and sections
var notes
var sections

var must_hit_section = false # if the section should be hit or not

# get the node paths for the strums
var PlayerStrum
var EnemyStrum

var MusicStream # might replace this because its only used like once

func _ready():
	# get the strums nodes
	PlayerStrum = get_node(PlayerStrumPath)
	EnemyStrum = get_node(EnemyStrumPath)
	
	MusicStream = get_tree().current_scene.get_node("Music/MusicStream") # get the music streams nodes
	
	setup_characters() # setup the characters positions and icons
	setup_strums() # setup the positions and stuff for strums
	
	rng.randomize() # randomize the rng variable's seed
	
	# tell the conductor to play the currently selected song
	# i might just remove the playstate entirely for this process, and only use the conductor
	Conductor.play_chart(song, difficulty, speed)
	
	var _c_beat = Conductor.connect("beat_hit", self, "icon_bop") # connect the beat hit signal to the icon bop

func _process(_delta):
	player_input() # handle the players input
	
	spawn_notes() # create the needed notes
	get_section() # get the current section
	
	# pause the game
	if (Input.is_action_just_pressed("confirm")):
		get_tree().paused = true
		var pauseMenu = PAUSE_SCREEN.instance()
		get_tree().current_scene.add_child(pauseMenu)
	
	# process health bar stuff, like positions
	health_bar_process()

func player_input():
	if (PlayerStrum == null || Settings.botPlay):
		return
	
	# ah
	button_logic(PlayerStrum, Note.Left)
	button_logic(PlayerStrum, Note.Down)
	button_logic(PlayerStrum, Note.Up)
	button_logic(PlayerStrum, Note.Right)

func button_logic(line, note):
	
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
	
	# get the nodes
	var button = line.get_node("Buttons/" + buttonName)
	var animation = button.get_node("AnimationPlayer")
	
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
		
		spawn_note(direction, strum_time, sustain_length)
		
func get_section():
	if (sections == null || sections.empty()):
		return
	
	var section = sections[0]
	
	if MusicStream.get_playback_position() >= section[0]:
		if (sections.has(section)):
			sections.erase(section)
			
		var character
		
		must_hit_section = section[1]
		if (must_hit_section):
			if (PlayerCharacter != null):
				character = PlayerCharacter
		else:
			if (EnemyCharacter != null):
				character = EnemyCharacter
		
		if (character != null):
			if (character.flipX):
				$Camera.position = character.position + character.camOffset
			else:
				$Camera.position = character.position + Vector2(-character.camOffset.x, character.camOffset.y)

func spawn_note(dir, strum_time, sustain_length):
	if (dir > 7):
		dir = 7
	if (dir < 0):
		dir = 0
	
	var strumLine = PlayerStrum
	
	if (dir > 3):
		strumLine = EnemyStrum
		dir -= 4
	
	if (strumLine != null):
		var note = NOTE_NODE.instance()
		
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
		
		strumLine.get_node("Notes").add_child(note)
		
		note.position.x = spawn_lane.position.x
		note.position.y = 1280
		
		note.strum_lane = spawn_lane
		note.strum_time = strum_time
		note.sustain_length = sustain_length
		note.note_type = dir
		
		if (strumLine == PlayerStrum):
			note.must_hit = true

func on_hit(must_hit, note_type, timing):
	var character = EnemyCharacter
	if (must_hit):
		character = PlayerCharacter
	
	if (character != null):
		var animName = player_sprite(note_type, "")
		character.play(animName)
		
		if (Settings.cameraMovement):
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
			
	if (must_hit):
		var rating = get_rating(timing)
		
		$HUD/Debug/RatingMS.text = str(round(timing)) + "MS"
		
		var timingData = HIT_TIMINGS[rating]
		score += timingData[1]
		health += 1.5
		combo += 1
		
		hitNotesArray.append(timing)
		
		create_rating(HIT_TIMINGS.keys().find(rating))
		
	Conductor.muteVocals = false

func on_miss(must_hit, note_type, passed = false):
	var character = EnemyCharacter
	if (must_hit):
		character = PlayerCharacter
	
	if (character != null):
		var animName = player_sprite(note_type, "Miss")
		character.play(animName)
	
	$HUD/Debug/RatingMS.text = ""
	
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
	combo = 0

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

func health_bar_process():
	var bar = $HUD/HealthBar
	var icons = $HUD/HealthBar/Icons
	
	health = clamp(health, 0, 100)
	
	bar.value = health
	icons.position.x = -(bar.value * (bar.rect_size.x / 100)) + bar.rect_size.x
	
	if (bar.value > 90):
		$HUD/HealthBar/Icons/Enemy.frame = 1
		
		if ($HUD/HealthBar/Icons/Player.hframes > 2):
			$HUD/HealthBar/Icons/Player.frame = 2
		else:
			$HUD/HealthBar/Icons/Player.frame = 0
	elif (bar.value < 10):
		$HUD/HealthBar/Icons/Player.frame = 1
		
		if ($HUD/HealthBar/Icons/Player.hframes > 2):
			$HUD/HealthBar/Icons/Enemy.frame = 2
		else:
			$HUD/HealthBar/Icons/Enemy.frame = 0
	else:
		$HUD/HealthBar/Icons/Enemy.frame = 0
		$HUD/HealthBar/Icons/Player.frame = 0
	
	var accuracyString = "N/A"
	var letterRating = ""
	if (!hitNotesArray.empty()):
		var totalNotes = float(hitNotesArray.size() + realMisses)
		var accuracy = round((float(hitNotesArray.size()) / totalNotes) * 100)
		
		accuracyString = str(accuracy) + "%"
		letterRating = " [" + get_letter_rating(accuracy) + "]"
	
	$HUD/TextBar.text = "Health: " + str(health) + "% | Score: " + str(score) + " | Misses: " + str(misses + realMisses) + " | " + accuracyString + letterRating
	$HUD/Debug/Rating.text = str(combo)
	
	$HUD/Background.color.a = Settings.backgroundOpacity
		
func get_letter_rating(accuracy):
	var letterRatings = {"A+": 95, "A": 85, "B+": 77.5, "B": 72.5, "C+": 67.5, "C": 62.5, "D+": 57.5, "D": 52.5, "E": 45, "F": 20}
	
	if (realMisses == 0):
		return "FC"
	
	var chosenRating = letterRatings.keys()[letterRatings.keys().size()-1]
	
	for rating in letterRatings.keys():
		if (accuracy >= letterRatings[rating]):
			chosenRating = rating
			break
	
	return chosenRating

func icon_bop():
	$HUD/HealthBar/Icons/AnimationPlayer.play("Bop")

func setup_characters():
	if (GFCharacter != null):
		GFCharacter = GFCharacter.instance()
		$Characters.add_child(GFCharacter)
		
		GFCharacter.position = $Positions/Girlfriend.position
	
	if (EnemyCharacter != null):
		EnemyCharacter = EnemyCharacter.instance()
		$Characters.add_child(EnemyCharacter)
		
		if (EnemyCharacter.girlfriendPosition):
			EnemyCharacter.position = $Positions/Girlfriend.position
		else:
			EnemyCharacter.position = $Positions/Enemy.position
			EnemyCharacter.flipX = !EnemyCharacter.flipX
		
		setup_icon($HUD/HealthBar/Icons/Enemy, EnemyCharacter)
		$HUD/HealthBar.tint_under = EnemyCharacter.characterColor
	
	if (PlayerCharacter != null):
		PlayerCharacter = PlayerCharacter.instance()
		$Characters.add_child(PlayerCharacter)
		
		if (PlayerCharacter.girlfriendPosition):
			PlayerCharacter.position = $Positions/Girlfriend.position
		else:
			PlayerCharacter.position = $Positions/Player.position
		
		setup_icon($HUD/HealthBar/Icons/Player, PlayerCharacter)
		$HUD/HealthBar.tint_progress = PlayerCharacter.characterColor

func setup_icon(node, character):
	var frames = character.iconSheet.get_width() / 150
	
	node.texture = character.iconSheet
	node.hframes = frames
	
func setup_strums():
	if (Settings.downScroll):
		PlayerStrum.position.y = 890
		PlayerStrum.scale.y = -PlayerStrum.scale.y
		
		EnemyStrum.position.y = 890
		EnemyStrum.scale.y = -EnemyStrum.scale.y
		
		$HUD/HealthBar.rect_position.y = 100
		$HUD/TextBar.rect_position.y = 50
		
		$HUD/Debug.position.y += 50
		
	if (Settings.middleScroll):
		PlayerStrum.position.x = 675
		
		if (Settings.middleScrollPreview):
			if (!Settings.downScroll):
				EnemyStrum.position = Vector2(145, 300)
			else:
				EnemyStrum.position = Vector2(145, 730)
			
			EnemyStrum.scale = EnemyStrum.scale * 0.5
		else:
			EnemyStrum.visible = false
	
	for button in EnemyStrum.get_node("Buttons").get_children():
		button.enemyStrum = true

func create_rating(rating):
	var ratingObj = RATING_SCENE.instance()
	ratingObj.get_node("Sprite").frame = rating
	
	if (!Settings.hudRatings):
		ratingObj.position = $Positions/Rating.position
		$Ratings.add_child(ratingObj)
	else:
		ratingObj.position = Settings.hudRatingsOffset / 0.7
		ratingObj.get_node("Sprite").scale = Vector2(1, 1)
		$HUD.add_child(ratingObj)

func restart_playstate():
	Main.change_playstate(song, difficulty, speed)
